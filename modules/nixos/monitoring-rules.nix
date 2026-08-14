{
  config,
  lib,
  ...
}:
let
  cfg = config.homelab.monitoring;

  inherit (lib) mkIf optionals;

  # Real, writable storage only. Pseudo-filesystems are always "full" or always
  # empty and would either alert forever or never.
  realFilesystems = ''fstype!~"tmpfs|ramfs|overlay|squashfs|iso9660|autofs|nsfs|devtmpfs|efivarfs|fuse.*"'';

  # Timers report 0 until their first run, so a naive `time() - last` produces
  # a 56-year staleness and pages immediately after every reboot.
  timerStale = timer: seconds: ''
    node_systemd_timer_last_trigger_seconds{name="${timer}"} > 0
      and
    time() - node_systemd_timer_last_trigger_seconds{name="${timer}"} > ${toString seconds}
  '';

  alertGroups = {
    groups = [
      {
        name = "meta";
        rules = [
          {
            alert = "Watchdog";
            expr = "vector(1)";
            labels = {
              severity = "none";
              component = "meta";
            };
            annotations = {
              summary = "Alerting pipeline is alive";
              description = ''
                This alert always fires. It is delivered only to the external
                dead man's switch, which pages when the notifications stop.
                Its absence is the signal, not its presence.
              '';
            };
          }
          {
            alert = "TargetDown";
            expr = "up == 0";
            for = "5m";
            labels = {
              severity = "critical";
              component = "availability";
            };
            annotations = {
              summary = "Prometheus cannot scrape {{ $labels.job }}";
              description = "{{ $labels.instance }} has been unreachable for 5 minutes.";
            };
          }
        ];
      }

      {
        name = "services";
        rules = [
          {
            alert = "SystemdUnitFailed";
            expr = ''node_systemd_unit_state{state="failed"} == 1'';
            for = "5m";
            labels = {
              severity = "critical";
              component = "services";
            };
            annotations = {
              summary = "{{ $labels.name }} has failed";
              description = ''
                The unit has been in the failed state for 5 minutes. This one
                rule covers service crashes, failed backups, and failed release
                deployments, because all three surface as a failed unit.
              '';
            };
          }
          {
            alert = "SystemdSystemDegraded";
            expr = "node_systemd_system_running == 0";
            for = "15m";
            labels = {
              severity = "warning";
              component = "services";
            };
            annotations = {
              summary = "systemd reports the system as degraded";
              description = "At least one unit is failed or stuck. Run systemctl --failed.";
            };
          }
        ];
      }

      {
        name = "scheduled-work";
        rules = [
          {
            alert = "MinecraftBackupStale";
            expr = timerStale "minecraft-backup.timer" 172800;
            for = "1h";
            labels = {
              severity = "critical";
              component = "backup";
            };
            annotations = {
              summary = "No Minecraft backup in over 48 hours";
              description = ''
                The daily backup timer has not fired. A backup that silently
                stops running looks identical to a healthy system until a
                restore is needed.
              '';
            };
          }
          {
            alert = "ReleaseUpdaterStale";
            expr = timerStale "caz-release-updater.timer" 172800;
            for = "1h";
            labels = {
              severity = "warning";
              component = "deployment";
            };
            annotations = {
              summary = "The release updater has not run in over 48 hours";
              description = "Verified releases are no longer being checked or deployed.";
            };
          }
          {
            alert = "ScheduledTimerNeverRan";
            expr = ''
              node_systemd_timer_last_trigger_seconds{name=~"minecraft-backup.timer|caz-release-updater.timer"} == 0
            '';
            for = "24h";
            labels = {
              severity = "warning";
              component = "deployment";
            };
            annotations = {
              summary = "{{ $labels.name }} has never triggered";
              description = "The timer has been installed for a day without running once.";
            };
          }
        ];
      }

      {
        name = "storage-capacity";
        rules = [
          {
            alert = "FilesystemSpaceLow";
            expr = ''
              100 * node_filesystem_avail_bytes{${realFilesystems}}
                / node_filesystem_size_bytes{${realFilesystems}} < ${toString cfg.diskWarnPercent}
            '';
            for = "30m";
            labels = {
              severity = "warning";
              component = "filesystem";
            };
            annotations = {
              summary = "{{ $labels.mountpoint }} is below ${toString cfg.diskWarnPercent}% free";
              description = "{{ $value | printf \"%.1f\" }}% free on {{ $labels.device }}.";
            };
          }
          {
            alert = "FilesystemSpaceCritical";
            expr = ''
              100 * node_filesystem_avail_bytes{${realFilesystems}}
                / node_filesystem_size_bytes{${realFilesystems}} < ${toString cfg.diskCriticalPercent}
            '';
            for = "10m";
            labels = {
              severity = "critical";
              component = "filesystem";
            };
            annotations = {
              summary = "{{ $labels.mountpoint }} is critically full";
              description = "{{ $value | printf \"%.1f\" }}% free on {{ $labels.device }}.";
            };
          }
          {
            alert = "FilesystemFillingUp";
            expr = ''
              predict_linear(node_filesystem_avail_bytes{${realFilesystems}}[6h], 24 * 3600) < 0
                and
              node_filesystem_avail_bytes{${realFilesystems}} > 0
            '';
            for = "1h";
            labels = {
              severity = "warning";
              component = "filesystem";
            };
            annotations = {
              summary = "{{ $labels.mountpoint }} will fill within 24 hours";
              description = ''
                Extrapolating the last six hours of usage. Catches runaway logs
                or a stuck job well before the disk is actually full.
              '';
            };
          }
          {
            alert = "FilesystemReadOnly";
            expr = "node_filesystem_readonly{${realFilesystems}} == 1";
            for = "5m";
            labels = {
              severity = "critical";
              component = "filesystem";
            };
            annotations = {
              summary = "{{ $labels.mountpoint }} has been remounted read-only";
              description = "Usually the kernel reacting to I/O errors. Check dmesg and SMART.";
            };
          }
        ];
      }

      {
        name = "disk-health";
        rules = [
          {
            alert = "SmartHealthFailing";
            expr = "smartctl_device_smart_status == 0";
            for = "5m";
            labels = {
              severity = "critical";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} reports SMART failure";
              description = ''
                The drive's own overall health assessment has failed. Treat the
                data on it as at risk and stop trusting it as a unique copy.
              '';
            };
          }
          {
            alert = "SmartSelfTestFailed";
            expr = "smartctl_device_self_test_log_error_count > 0";
            for = "15m";
            labels = {
              severity = "critical";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} failed a SMART self-test";
              description = ''
                A scheduled self-test recorded an error. This is exactly the
                signal that condemned the old spinning disk.
              '';
            };
          }
          {
            alert = "SmartReallocatedSectors";
            expr = ''
              smartctl_device_attribute{attribute_name="Reallocated_Sector_Ct",attribute_value_type="raw"} > 0
            '';
            for = "15m";
            labels = {
              severity = "warning";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} has reallocated sectors";
              description = "Any non-zero count means the drive has already lost sectors.";
            };
          }
          {
            alert = "NvmeCriticalWarning";
            expr = "smartctl_device_critical_warning > 0";
            for = "5m";
            labels = {
              severity = "critical";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} raised an NVMe critical warning";
              description = "Reported by the drive itself: spare, reliability, thermal, or media.";
            };
          }
          {
            alert = "NvmeMediaErrors";
            expr = "increase(smartctl_device_media_errors[6h]) > 0";
            labels = {
              severity = "warning";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} recorded new media errors";
              description = "Unrecovered data integrity errors increased in the last six hours.";
            };
          }
          {
            alert = "NvmeSpareLow";
            expr = "smartctl_device_available_spare < smartctl_device_available_spare_threshold";
            for = "30m";
            labels = {
              severity = "critical";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} is below its spare block threshold";
              description = "The drive is running out of replacement blocks and is near end of life.";
            };
          }
          {
            alert = "NvmeWearHigh";
            expr = "smartctl_device_percentage_used > 85";
            for = "1h";
            labels = {
              severity = "warning";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} has used {{ $value }}% of its rated endurance";
              description = "Plan a replacement before this reaches 100%.";
            };
          }
          {
            alert = "DriveTemperatureHigh";
            expr = ''
              smartctl_device_temperature{temperature_type="current"} > ${toString cfg.diskTemperatureWarnCelsius}
            '';
            for = "20m";
            labels = {
              severity = "warning";
              component = "disk";
            };
            annotations = {
              summary = "{{ $labels.device }} is running at {{ $value }}C";
              description = "Sustained heat shortens drive life. Check airflow.";
            };
          }
        ];
      }

      {
        name = "host-resources";
        rules = [
          {
            alert = "HostTemperatureHigh";
            expr = "node_hwmon_temp_celsius > ${toString cfg.temperatureWarnCelsius}";
            for = "10m";
            labels = {
              severity = "warning";
              component = "thermal";
            };
            annotations = {
              summary = "{{ $labels.chip }} sensor reads {{ $value }}C";
              description = "Sustained above threshold. Check fans, dust, and Minecraft or transcode load.";
            };
          }
          {
            alert = "MemoryPressure";
            expr = ''
              100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 10
            '';
            for = "20m";
            labels = {
              severity = "warning";
              component = "memory";
            };
            annotations = {
              summary = "Less than 10% of memory is available";
              description = "{{ $value | printf \"%.1f\" }}% available. Check for a runaway service.";
            };
          }
          {
            alert = "OutOfMemoryKill";
            expr = "increase(node_vmstat_oom_kill[1h]) > 0";
            labels = {
              severity = "critical";
              component = "memory";
            };
            annotations = {
              summary = "The kernel OOM killer terminated a process";
              description = "Something exceeded available memory in the last hour.";
            };
          }
        ];
      }
    ]
    ++ optionals config.services.auxide.enable [
      {
        name = "auxide";
        rules = [
          {
            alert = "AuxideNotReady";
            expr = "auxide_ready == 0";
            for = "15m";
            labels = {
              severity = "warning";
              component = "auxide";
            };
            annotations = {
              summary = "Auxide is running but not ready to accept commands";
              description = "The bot process is up while its readiness gate is closed.";
            };
          }
          {
            alert = "AuxideDiscordDisconnected";
            expr = "auxide_discord_connected == 0";
            for = "15m";
            labels = {
              severity = "warning";
              component = "auxide";
            };
            annotations = {
              summary = "Auxide has lost its Discord gateway connection";
              description = "Sustained disconnection beyond normal reconnect behaviour.";
            };
          }
        ];
      }
    ];
  };
in
{
  config = mkIf cfg.enable {
    # JSON is valid YAML, and promtool validates every expression at build time
    # because services.prometheus.checkConfig is enabled.
    services.prometheus.rules = [ (builtins.toJSON alertGroups) ];
  };
}
