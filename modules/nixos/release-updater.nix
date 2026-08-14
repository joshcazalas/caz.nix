{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.releaseUpdater;
  inherit (lib)
    concatStringsSep
    optionals
    ;

  minecraftEnabled = config.homelab.minecraft.enable;
  requiredUnits =
    optionals config.services.openssh.enable [ "sshd.service" ]
    ++ optionals config.services.samba.enable [ "samba-smbd.service" ]
    ++ optionals config.services.jellyfin.enable [ "jellyfin.service" ]
    ++ optionals config.services.adguardhome.enable [ "adguardhome.service" ]
    ++ optionals config.services.beszel.hub.enable [ "beszel-hub.service" ]
    ++ optionals config.services.cloudflare-ddns.enable [ "cloudflare-ddns.service" ]
    ++ optionals config.services.fail2ban.enable [ "fail2ban.service" ]
    ++ optionals config.homelab.homeAssistant.enable [ "home-assistant.service" ]
    ++ optionals config.homelab.immich.enable [ "immich-server.service" ]
    ++ optionals minecraftEnabled [ "docker-minecraft.service" ]
    ++ optionals config.services.caddy.enable [ "caddy.service" ];
  requiredSockets = optionals (minecraftEnabled && config.homelab.minecraft.openFirewall) [
    "minecraft-proxy.socket"
  ];
  httpEndpoints =
    optionals config.services.jellyfin.enable [ "jellyfin=http://127.0.0.1:8096/health" ]
    ++ optionals config.services.adguardhome.enable [ "adguardhome=http://127.0.0.1:3000/" ]
    ++ optionals config.services.beszel.hub.enable [ "beszel=http://127.0.0.1:8090/" ]
    ++ optionals config.homelab.homeAssistant.enable [ "home-assistant=http://127.0.0.1:8123/" ]
    ++ optionals config.homelab.immich.enable [ "immich=http://127.0.0.1:2283/api/server/ping" ];

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
    ++ optionals config.services.beszel.hub.enable [ "beszel-hub.service" ];
  backupStatePaths =
    optionals config.services.samba.enable [ "var/lib/samba" ]
    ++ optionals config.services.jellyfin.enable [ "var/lib/jellyfin" ]
    ++ optionals config.services.adguardhome.enable [ "var/lib/AdGuardHome" ]
    ++ optionals config.services.beszel.hub.enable [ "var/lib/beszel-hub" ];
  preDeployBackup = pkgs.writeShellApplication {
    name = "caz-pre-deployment-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnutar
      pkgs.systemd
      pkgs.zstd
    ];
    text = ''
      export CAZ_BACKUP_DIRECTORY=/var/backup/caz-release-updater
      export CAZ_BACKUP_RETENTION_COUNT=${toString cfg.stateBackupRetention}
      export CAZ_BACKUP_PAUSE_UNITS=${lib.escapeShellArg (concatStringsSep " " pauseUnits)}
      export CAZ_BACKUP_STATE_PATHS=${lib.escapeShellArg (concatStringsSep " " backupStatePaths)}

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
      preDeployBackup
      serverHealth
    ];
    text = ''
      export CAZ_RELEASE_HEALTH_WAIT_SECONDS=${toString cfg.healthWaitSeconds}
      export CAZ_RELEASE_STABILIZATION_SECONDS=${toString cfg.stabilizationSeconds}

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
      default = 300;
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
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = minecraftEnabled;
        message = "The initial release updater safety policy requires the Minecraft backup service.";
      }
      {
        assertion = backupStatePaths != [ ];
        message = "Automatic deployment requires at least one application state path to protect.";
      }
    ];

    environment.systemPackages = [
      preDeployBackup
      serverHealth
      updater
    ];

    systemd.tmpfiles.rules = [
      "d /var/backup/caz-release-updater 0700 root root -"
    ];

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
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe updater;
        CacheDirectory = "caz-release-updater";
        StateDirectory = "caz-release-updater";
        RuntimeDirectory = "caz-release-updater";
        TimeoutStartSec = "3h";
        UMask = "0077";

        # This root unit must update the NixOS system profile, bootloader, and
        # running services. Retain hardening controls that do not block those
        # explicit responsibilities.
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
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

    warnings =
      optionals config.homelab.immich.enable [
        ''
          Immich is enabled but its PostgreSQL database is not yet included in
          the automatic pre-deployment backup. Add an application-native backup
          before relying on unattended Immich schema migrations.
        ''
      ]
      ++ optionals config.homelab.homeAssistant.enable [
        ''
          Home Assistant is enabled but its state is not yet included in the
          automatic pre-deployment backup. Extend the backup policy first.
        ''
      ];
  };
}
