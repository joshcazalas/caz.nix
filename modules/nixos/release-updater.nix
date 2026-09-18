{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  cfg = config.homelab.releaseUpdater;
  inherit (lib)
    all
    concatStringsSep
    optionals
    ;

  # switch-to-configuration executes the new generation's activation script in
  # this service's execution context. These settings isolate exactly the host
  # state that NixOS activation is responsible for updating. Keep the contract
  # explicit so a future hardening pass fails evaluation instead of failing a
  # live activation and its rollback.
  activationBlockingServiceSettings = [
    "ProtectControlGroups"
    "ProtectHome"
    "ProtectHostname"
    "ProtectKernelModules"
    "ProtectKernelTunables"
    "ProtectSystem"
  ];
  updaterServiceConfig = config.systemd.services.caz-release-updater.serviceConfig;

  notificationCommand = pkgs.writeShellScriptBin "caz-release-notifications" ''
    exec ${lib.getExe pkgs.python3} ${../../scripts/release-notifications.py} "$@"
  '';

  minecraftEnabled = config.homelab.minecraft.enable;
  factorioEnabled = config.services.factorio.enable;
  homeAssistantEnabled = config.homelab.homeAssistant.enable;
  homeAssistantUnit = "docker-homeassistant.service";
  homeAssistantStatePath = lib.removePrefix "/" config.homelab.homeAssistant.dataDir;
  containerMaintenanceLock = "/run/caz-container-maintenance/lock";

  # Auxide keeps answering commands without its proof-of-origin provider, so
  # nothing here fails when it dies -- it just quietly costs whole tracks,
  # which is why a deployment could report itself healthy while the provider
  # had been down the entire time. Gated on both switches because the provider
  # is optional even when Auxide is not.
  providerEnabled = config.services.auxide.enable && config.services.auxide.poTokenProvider.enable;
  providerUnit = "${config.virtualisation.oci-containers.backend}-auxide-pot-provider.service";
  requiredUnits =
    optionals config.services.openssh.enable [ "sshd.service" ]
    ++ optionals config.services.samba.enable [ "samba-smbd.service" ]
    ++ optionals config.services.jellyfin.enable [ "jellyfin.service" ]
    ++ optionals config.services.adguardhome.enable [ "adguardhome.service" ]
    ++ optionals config.services.prometheus.enable [
      "prometheus.service"
      "prometheus-node-exporter.service"
      "prometheus-smartctl-exporter.service"
    ]
    ++ optionals config.services.prometheus.alertmanager.enable [ "alertmanager.service" ]
    ++ optionals config.services.grafana.enable [ "grafana.service" ]
    ++ optionals config.services.cloudflare-ddns.enable [ "cloudflare-ddns.service" ]
    ++ optionals config.services.fail2ban.enable [ "fail2ban.service" ]
    ++ optionals config.homelab.gameStreamGateway.enable [
      "wg-quick-wg-game.service"
    ]
    ++ optionals config.homelab.homeAccessGateway.enable [
      "wg-quick-wg-home.service"
    ]
    ++ optionals config.services.auxide.enable [ "auxide.service" ]
    ++ optionals providerEnabled [ providerUnit ]
    ++ optionals homeAssistantEnabled [ homeAssistantUnit ]
    ++ optionals config.homelab.immich.enable [ "immich-server.service" ]
    ++ optionals minecraftEnabled [ "docker-minecraft.service" ]
    ++ optionals factorioEnabled [ "factorio.service" ]
    ++ optionals config.services.caddy.enable [ "caddy.service" ];
  requiredSockets = optionals (minecraftEnabled && config.homelab.minecraft.openFirewall) [
    "minecraft-proxy.socket"
  ];
  httpEndpoints =
    # NAME=accepted-statuses=URL. Only frontend probes accept a redirect;
    # dedicated health/readiness endpoints must actually report success.
    optionals config.services.jellyfin.enable [ "jellyfin=200=http://127.0.0.1:8096/health" ]
    ++ optionals config.services.adguardhome.enable [ "adguardhome=200,302=http://127.0.0.1:3000/" ]
    ++ optionals config.services.prometheus.enable [
      "prometheus=200=http://127.0.0.1:${toString config.services.prometheus.port}/-/healthy"
    ]
    ++ optionals config.services.prometheus.alertmanager.enable [
      "alertmanager=200=http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}/-/healthy"
    ]
    ++ optionals config.services.grafana.enable [
      "grafana=200=http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}/api/health"
    ]
    ++ optionals homeAssistantEnabled [ "home-assistant=200,302=http://127.0.0.1:8123/" ]
    ++ optionals config.homelab.immich.enable [ "immich=200=http://127.0.0.1:2283/api/server/ping" ]
    ++ optionals config.services.auxide.enable [ "auxide=200=http://127.0.0.1:9090/health/ready" ]
    # The unit check above proves systemd still has it; this proves the token
    # server's /ping endpoint actually succeeds, not merely that a listener
    # can return a 404 for an unknown route.
    ++ optionals providerEnabled [
      "auxide-pot-provider=200=http://127.0.0.1:${toString config.services.auxide.poTokenProvider.port}/ping"
    ];

  serverHealth = pkgs.writeShellApplication {
    name = "caz-server-health";
    runtimeInputs = [
      pkgs.bind.dnsutils
      pkgs.coreutils
      pkgs.curl
      pkgs.docker
      pkgs.gnugrep
      pkgs.systemd
    ];
    text = ''
      export CAZ_HEALTH_REQUIRED_UNITS=${lib.escapeShellArg (concatStringsSep " " requiredUnits)}
      export CAZ_HEALTH_REQUIRED_SOCKETS=${lib.escapeShellArg (concatStringsSep " " requiredSockets)}
      export CAZ_HEALTH_HTTP_ENDPOINTS=${lib.escapeShellArg (concatStringsSep " " httpEndpoints)}
      export CAZ_HEALTH_CHECK_DNS=${lib.boolToString config.services.adguardhome.enable}
      export CAZ_HEALTH_CHECK_MINECRAFT=${lib.boolToString minecraftEnabled}
      export CAZ_HEALTH_CHECK_FACTORIO=${lib.boolToString factorioEnabled}
      export CAZ_HEALTH_FACTORIO_COMMAND=/run/current-system/sw/bin/factorio-access

      ${builtins.readFile ../../scripts/check-server-health.sh}
    '';
  };

  pauseUnits =
    optionals config.services.samba.enable [
      "samba-smbd.service"
      "samba-nmbd.service"
      "samba-winbindd.service"
    ]
    ++ optionals config.services.jellyfin.enable [ "jellyfin.service" ]
    ++ optionals config.services.adguardhome.enable [ "adguardhome.service" ]
    ++ optionals config.services.grafana.enable [ "grafana.service" ]
    ++ optionals homeAssistantEnabled [ homeAssistantUnit ];
  backupStatePaths =
    optionals config.services.samba.enable [ "var/lib/samba" ]
    ++ optionals config.services.jellyfin.enable [ "var/lib/jellyfin" ]
    ++ optionals config.services.adguardhome.enable [ "var/lib/AdGuardHome" ]
    # Grafana's database is small and holds annotations and preferences.
    # Prometheus' TSDB is deliberately excluded: it is large, rewritten
    # constantly, and reproducible by simply scraping again.
    ++ optionals config.services.grafana.enable [ "var/lib/grafana" ]
    # Stop the container before archiving its SQLite database. This protects
    # UI-managed integrations, automations, credentials, and history together.
    ++ optionals homeAssistantEnabled [ homeAssistantStatePath ];

  storagePaths = lib.unique (
    [
      "/"
      "/nix/store"
      "/nix/var/nix/profiles"
      config.boot.loader.efi.efiSysMountPoint
      "/var/lib/caz-release-updater"
      "/var/backup/caz-release-updater"
      settings.server.dataRoot
      "${settings.server.dataRoot}/media"
      "${settings.server.dataRoot}/shares"
    ]
    ++ map (path: "/${path}") backupStatePaths
    ++ optionals minecraftEnabled [
      config.homelab.minecraft.dataDir
      config.homelab.minecraft.backupDir
    ]
    ++ optionals factorioEnabled [
      "/var/lib/${config.services.factorio.stateDirName}"
      "/var/backup/factorio"
    ]
  );
  # Longest containing mount wins. A missing mount must not silently fall back
  # to the parent filesystem, including /boot falling back to the root NVMe.
  filesystemFor =
    path:
    config.fileSystems.${
      builtins.head (
        lib.sort (a: b: builtins.stringLength a > builtins.stringLength b) (
          builtins.filter (mount: mount == "/" || path == mount || lib.hasPrefix "${mount}/" path) (
            builtins.attrNames config.fileSystems
          )
        )
      )
    };
  storageRequirements = map (path: {
    inherit path;
    filesystem = {
      inherit (filesystemFor path) mountPoint device fsType;
    };
    minimumFreeMiB =
      if path == config.boot.loader.efi.efiSysMountPoint then
        cfg.storagePreflight.minimumBootFreeMiB
      else
        cfg.storagePreflight.minimumFreeMiB;
    inherit (cfg.storagePreflight) minimumFreeInodes;
  }) storagePaths;
  storagePreflight = pkgs.writeShellApplication {
    name = "caz-check-deployment-storage";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      exec ${lib.getExe pkgs.python3} ${../../scripts/check-deployment-storage.py} \
        --config ${pkgs.writeText "deployment-storage.json" (builtins.toJSON storageRequirements)} "$@"
    '';
  };

  preDeployBackup = pkgs.writeShellApplication {
    name = "caz-pre-deployment-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnutar
      pkgs.systemd
      pkgs.util-linux
      pkgs.zstd
    ];
    text = ''
      export CAZ_BACKUP_DIRECTORY=/var/backup/caz-release-updater
      export CAZ_BACKUP_RETENTION_COUNT=${toString cfg.stateBackupRetention}
      export CAZ_BACKUP_FACTORIO=${lib.boolToString factorioEnabled}
      export CAZ_BACKUP_FACTORIO_COMMAND=/run/current-system/sw/bin/factorio-access
      export CAZ_BACKUP_PAUSE_UNITS=${lib.escapeShellArg (concatStringsSep " " pauseUnits)}
      export CAZ_BACKUP_STATE_PATHS=${lib.escapeShellArg (concatStringsSep " " backupStatePaths)}
      export CAZ_CONTAINER_MAINTENANCE_LOCK=${lib.escapeShellArg containerMaintenanceLock}

      ${builtins.readFile ../../scripts/pre-deploy-backup.sh}
    '';
  };

  updater = pkgs.writeShellApplication {
    name = "caz-deploy-server-release";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.curl
      pkgs.gh
      pkgs.gnugrep
      pkgs.gawk
      pkgs.jq
      pkgs.snzip
      pkgs.util-linux
      # The pre-deployment backup describes the state that exists *now*, so the
      # copy built alongside this updater is the correct one.
      preDeployBackup
      storagePreflight
      # serverHealth is deliberately absent. The health gate must describe the
      # generation that is actually running, so the script resolves it through
      # /run/current-system instead. Putting it back here would silently
      # reintroduce a stale gate that fails every release removing a service.
    ];
    text = ''
      export CAZ_RELEASE_HEALTH_WAIT_SECONDS=${toString cfg.healthWaitSeconds}
      export CAZ_RELEASE_STABILIZATION_SECONDS=${toString cfg.stabilizationSeconds}
      export CAZ_CONTAINER_MAINTENANCE_LOCK=${lib.escapeShellArg containerMaintenanceLock}
      export CAZ_RELEASE_NOTIFICATION_COMMAND=${
        lib.escapeShellArg (if cfg.notifications.enable then lib.getExe notificationCommand else "")
      }
      export CAZ_RELEASE_NOTIFICATION_INSTANCE=${lib.escapeShellArg config.networking.hostName}

      ${builtins.readFile ../../scripts/stage-server-release.sh}
    '';
  };
in
{
  options.homelab.releaseUpdater = {
    enable = lib.mkEnableOption "verified automatic caz.nix release deployment";

    repository = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
      default = "joshcazalas/caz.nix";
      description = "Public GitHub repository that publishes trusted caz.nix releases.";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:00:00";
      description = "systemd calendar expression controlling the deployment maintenance window.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "2h";
      description = "Stable randomized delay applied inside the deployment maintenance window.";
    };

    healthWaitSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Maximum time for services to become healthy after activation or rollback.";
    };

    stabilizationSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Time all post-deployment health checks must remain healthy.";
    };

    stateBackupRetention = lib.mkOption {
      type = lib.types.ints.between 1 10;
      default = 3;
      description = "Number of local pre-deployment application-state archives to retain.";
    };

    notifications.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.homelab.monitoring.enable;
      description = "Queue timer-triggered deployment events for the existing local Alertmanager email/Discord receiver; manual runs stay quiet.";
    };

    storagePreflight = {
      minimumFreeMiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2048;
        description = "Minimum available MiB on the store, state, and backup filesystems before deployment work.";
      };
      minimumBootFreeMiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 128;
        description = "Minimum available MiB on the EFI filesystem before deployment work.";
      };
      minimumFreeInodes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1024;
        description = "Minimum available inodes on filesystems that report an inode pool.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.notifications.enable || config.homelab.monitoring.enable;
        message = "Release notifications require the existing homelab monitoring configuration.";
      }
      {
        assertion = minecraftEnabled;
        message = "The initial release updater safety policy requires the Minecraft backup service.";
      }
      {
        assertion = backupStatePaths != [ ];
        message = "Automatic deployment requires at least one application state path to protect.";
      }
      {
        assertion = all (
          setting: (updaterServiceConfig.${setting} or false) == false
        ) activationBlockingServiceSettings;
        message = ''
          caz-release-updater must run without host-isolating Protect* settings.
          switch-to-configuration executes NixOS activation and rollback inside
          the updater's service context, where it must manage users, boot state,
          kernel settings, modules, the hostname, cgroups, and system files.
        '';
      }
    ];

    environment.systemPackages = [
      preDeployBackup
      storagePreflight
      serverHealth
      updater
    ];

    systemd.tmpfiles.rules = [
      "d /var/backup/caz-release-updater 0700 root root -"
    ];

    systemd.services.caz-release-notifications = lib.mkIf cfg.notifications.enable {
      description = "Submit queued deployment events to local Alertmanager";
      wants = [ "alertmanager.service" ];
      after = [ "alertmanager.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''
          ${lib.getExe notificationCommand} --queue /var/lib/caz-release-updater/notifications drain --endpoint http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}/api/v2/alerts
        '';
        StateDirectory = "caz-release-updater";
        StateDirectoryMode = "0700";
        UMask = "0077";
        TimeoutStartSec = "90s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_INET" ];
        IPAddressDeny = "any";
        IPAddressAllow = "127.0.0.1/32";
      };
    };

    systemd.timers.caz-release-notifications = lib.mkIf cfg.notifications.enable {
      description = "Retry queued deployment notifications every minute";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitInactiveSec = "1m";
      };
    };

    systemd.services.caz-release-updater = {
      description = "Verify, deploy, and health-check the latest caz.nix homeserver release";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      # Do not let activation restart or remove the process supervising that
      # same activation. The old updater remains responsible through health
      # checks and any rollback; the next run uses the newly deployed unit.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;

      environment = {
        CAZ_RELEASE_REPOSITORY = cfg.repository;
        XDG_CACHE_HOME = "/var/cache/caz-release-updater";

        # Build through the Nix daemon instead of inside this unit.
        #
        # Nix's build sandbox creates mount, PID, network, IPC, and UTS
        # namespaces. The hardening below denies that, so a client building
        # in-process dies with "this system does not support the kernel
        # namespaces that are required for sandboxing". Root reaches the store
        # directly by default, so nothing routed the build elsewhere on its own.
        #
        # This only ever broke the timer. An administrator running the same
        # command from a shell inherits no such restrictions and builds fine,
        # which is why the fault stayed hidden until the first unattended run
        # that actually had something new to build.
        #
        # The obvious alternatives are both worse: --no-sandbox would quietly
        # weaken build isolation for every release, and relaxing the unit would
        # hand the updater privileges it otherwise never needs. The daemon
        # already exists to perform builds at the privilege they require on
        # behalf of confined clients, so both sandboxes stay intact.
        NIX_REMOTE = "daemon";
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe updater;
        CacheDirectory = "caz-release-updater";
        StateDirectory = "caz-release-updater";
        RuntimeDirectory = "caz-release-updater";
        TimeoutStartSec = "3h";
        UMask = "0077";

        # This root unit runs a cryptographically verified NixOS generation's
        # activation code. It must retain the host filesystem and kernel view
        # expected by switch-to-configuration; ProtectHome, ProtectSystem, and
        # the ProtectKernel*/ProtectControlGroups/ProtectHostname family are
        # therefore intentionally absent and guarded by the assertion above.
        # Keep process restrictions that do not interfere with host activation.
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        RestrictRealtime = true;
      };
    };

    systemd.timers.caz-release-updater = {
      description = "Deploy a new verified caz.nix homeserver release";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        FixedRandomDelay = true;
        Unit = "caz-release-updater.service";
      };
    };

    warnings = optionals config.homelab.immich.enable [
      ''
        Immich is enabled but its PostgreSQL database is not yet included in
        the automatic pre-deployment backup. Add an application-native backup
        before relying on unattended Immich schema migrations.
      ''
    ];
  };
}
