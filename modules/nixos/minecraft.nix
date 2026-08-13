{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  cfg = config.homelab.minecraft;
  # Keep the container's files away from the login user and Nix's reserved
  # 30001-30032 build-user range.
  minecraftUid = 20000;
  minecraftGid = 20000;
  playerNameType = lib.types.strMatching "[A-Za-z0-9_]{3,16}";
  whitelistContainerPath = "/run/caz-nix/minecraft-whitelist";
  operatorsContainerPath = "/run/caz-nix/minecraft-operators";
in
{
  options.homelab.minecraft = {
    enable = lib.mkEnableOption "the Paper Minecraft server";

    acceptEula = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Confirm acceptance of the Minecraft EULA.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "itzg/minecraft-server:2026.8.0-java25@sha256:e3335993929a1565f73c30b2041bcbc1473fc9c406fdd5a0d0ea24c08ef73320";
      description = "Immutable OCI image reference for the server runtime.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "26.2";
      description = "Exact Minecraft Java Edition version.";
    };

    paperBuild = lib.mkOption {
      type = lib.types.ints.positive;
      default = 87;
      description = "Exact stable Paper build for the selected Minecraft version.";
    };

    whitelist = lib.mkOption {
      type = lib.types.listOf playerNameType;
      default = [ ];
      description = "Minecraft usernames allowed to join. Values committed here are public.";
    };

    whitelistFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/minecraft-whitelist";
      description = ''
        Runtime path to a newline-separated whitelist, normally decrypted by
        sops-nix. Use this instead of whitelist to keep player names private.
      '';
    };

    operators = lib.mkOption {
      type = lib.types.listOf playerNameType;
      default = [ ];
      description = "Whitelisted Minecraft usernames granted operator privileges.";
    };

    operatorsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/minecraft-operators";
      description = ''
        Runtime path to a newline-separated operator list, normally decrypted
        by sops-nix. Use this instead of operators to keep names private.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Expose TCP 25565 to the LAN through a firewall-controlled systemd
        proxy. Internet access still requires a router port forward.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 25565;
      description = "Host TCP port exposed when openFirewall is enabled.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/minecraft";
      description = "World and server state directory on the healthy NVMe filesystem.";
    };

    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/backup/minecraft";
      description = "Local daily backup directory.";
    };

    backupRetentionDays = lib.mkOption {
      type = lib.types.ints.between 1 90;
      default = 7;
      description = "Number of compressed daily backups to retain locally.";
    };

    initialMemory = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "Initial Java heap size.";
    };

    maximumMemory = lib.mkOption {
      type = lib.types.str;
      default = "6G";
      description = "Maximum Java heap size.";
    };

    maxPlayers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Maximum simultaneous player count.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.enable || cfg.acceptEula;
          message = "Minecraft requires homelab.minecraft.acceptEula = true.";
        }
        {
          assertion = !cfg.enable || cfg.whitelist != [ ] || cfg.whitelistFile != null;
          message = "Minecraft requires a whitelist or whitelistFile.";
        }
        {
          assertion = cfg.whitelist == [ ] || cfg.whitelistFile == null;
          message = "Set either Minecraft whitelist or whitelistFile, not both.";
        }
        {
          assertion = cfg.operators == [ ] || cfg.operatorsFile == null;
          message = "Set either Minecraft operators or operatorsFile, not both.";
        }
        {
          assertion = lib.length cfg.whitelist == lib.length (lib.unique cfg.whitelist);
          message = "homelab.minecraft.whitelist must not contain duplicates.";
        }
        {
          assertion = lib.length cfg.operators == lib.length (lib.unique cfg.operators);
          message = "homelab.minecraft.operators must not contain duplicates.";
        }
        {
          assertion =
            cfg.whitelistFile != null
            || cfg.operatorsFile != null
            || lib.all (player: lib.elem player cfg.whitelist) cfg.operators;
          message = "Every Minecraft operator must also be in the whitelist.";
        }
        {
          assertion = cfg.port != 25566;
          message = "Minecraft host port 25566 is reserved for the loopback container mapping.";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      users.groups.minecraft.gid = minecraftGid;
      users.users.minecraft = {
        uid = minecraftUid;
        group = "minecraft";
        home = cfg.dataDir;
        isSystemUser = true;
      };

      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 ${toString minecraftUid} ${toString minecraftGid} -"
        "d ${cfg.backupDir} 0700 root root -"
      ];

      virtualisation.oci-containers.containers.minecraft = {
        inherit (cfg) image;
        autoStart = true;
        ports = [ "127.0.0.1:25566:25565/tcp" ];
        volumes = [
          "${cfg.dataDir}:/data:rw"
        ]
        ++ lib.optional (cfg.whitelistFile != null) "${cfg.whitelistFile}:${whitelistContainerPath}:ro"
        ++ lib.optional (cfg.operatorsFile != null) "${cfg.operatorsFile}:${operatorsContainerPath}:ro";
        environment = {
          EULA = "TRUE";
          TYPE = "PAPER";
          VERSION = cfg.version;
          PAPER_BUILD = toString cfg.paperBuild;
          PAPER_CHANNEL = "default";

          UID = toString minecraftUid;
          GID = toString minecraftGid;
          INIT_MEMORY = cfg.initialMemory;
          MAX_MEMORY = cfg.maximumMemory;
          TZ = settings.server.timeZone;

          ONLINE_MODE = "TRUE";
          ENFORCE_SECURE_PROFILE = "TRUE";
          ENABLE_WHITELIST = "TRUE";
          ENFORCE_WHITELIST = "TRUE";
          EXISTING_WHITELIST_FILE = "SYNCHRONIZE";
          EXISTING_OPS_FILE = "SYNCHRONIZE";

          OVERRIDE_SERVER_PROPERTIES = "TRUE";
          MODE = "survival";
          DIFFICULTY = "normal";
          PVP = "TRUE";
          MAX_PLAYERS = toString cfg.maxPlayers;
          VIEW_DISTANCE = "12";
          SIMULATION_DISTANCE = "8";
          SPAWN_PROTECTION = "16";
          ENABLE_QUERY = "FALSE";
          HIDE_ONLINE_PLAYERS = "TRUE";
          BROADCAST_CONSOLE_TO_OPS = "FALSE";
          BROADCAST_RCON_TO_OPS = "FALSE";
          SNOOPER_ENABLED = "FALSE";
          MOTD = "caz.nix Paper ${cfg.version}";

          # RCON stays inside the untrusted container network and is never
          # published. It enables synchronous, consistent online backups.
          ENABLE_RCON = "TRUE";
          GENERATE_LOG4J2_CONFIG = "TRUE";
          ROLLING_LOG_MAX_FILES = "30";
          STOP_DURATION = "120";
        }
        // lib.optionalAttrs (cfg.whitelist != [ ]) {
          WHITELIST = lib.concatStringsSep "," cfg.whitelist;
        }
        // lib.optionalAttrs (cfg.whitelistFile != null) {
          WHITELIST_FILE = whitelistContainerPath;
        }
        // lib.optionalAttrs (cfg.operators != [ ]) {
          OPS = lib.concatStringsSep "," cfg.operators;
        }
        // lib.optionalAttrs (cfg.operatorsFile != null) {
          OPS_FILE = operatorsContainerPath;
        };
        extraOptions = [
          "--init"
          "--memory=8g"
          "--pids-limit=512"
          "--security-opt=no-new-privileges:true"
        ];
      };

      systemd.services.docker-minecraft.serviceConfig.TimeoutStopSec = lib.mkForce 180;

      # Docker only publishes the game port on loopback. This host-level proxy
      # makes the NixOS firewall authoritative instead of letting Docker's NAT
      # rules silently bypass it.
      systemd.sockets.minecraft-proxy = lib.mkIf cfg.openFirewall {
        description = "Firewall-controlled Minecraft TCP listener";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "0.0.0.0:${toString cfg.port}" ];
        socketConfig.NoDelay = true;
      };

      systemd.services.minecraft-proxy = lib.mkIf cfg.openFirewall {
        description = "Proxy Minecraft TCP connections to the loopback-only container port";
        requires = [ "docker-minecraft.service" ];
        after = [ "docker-minecraft.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:25566";
          DynamicUser = true;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
        };
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

      systemd.services.minecraft-backup = {
        description = "Create a consistent compressed Minecraft world backup";
        after = [ "docker-minecraft.service" ];
        path = [
          pkgs.coreutils
          pkgs.docker
          pkgs.findutils
          pkgs.gnutar
          pkgs.zstd
        ];
        script = ''
          set -Eeuo pipefail

          if ! docker inspect minecraft >/dev/null 2>&1; then
            echo "Minecraft container does not exist; skipping backup"
            exit 0
          fi

          if test "$(docker inspect --format '{{.State.Running}}' minecraft)" != true; then
            echo "Minecraft container is not running; skipping backup"
            exit 0
          fi

          saving_disabled=false
          temporary_archive=""
          cleanup() {
            if test "$saving_disabled" = true; then
              docker exec minecraft rcon-cli save-on || true
            fi
            if test -n "$temporary_archive"; then
              rm -f -- "$temporary_archive"
            fi
          }
          trap cleanup EXIT

          docker exec minecraft rcon-cli save-off
          saving_disabled=true
          docker exec minecraft rcon-cli save-all flush

          temporary_archive="$(mktemp \
            --tmpdir=${lib.escapeShellArg cfg.backupDir} \
            --suffix=.tar.zst \
            .minecraft-backup.XXXXXX)"
          archive=${lib.escapeShellArg cfg.backupDir}/minecraft-$(date --utc +%Y%m%dT%H%M%SZ).tar.zst
          tar --create --zstd --file "$temporary_archive" \
            --exclude='./cache' \
            --exclude='./crash-reports' \
            --exclude='./logs' \
            --directory ${lib.escapeShellArg cfg.dataDir} .

          docker exec minecraft rcon-cli save-on
          saving_disabled=false
          mv -- "$temporary_archive" "$archive"
          temporary_archive=""

          find ${lib.escapeShellArg cfg.backupDir} \
            -maxdepth 1 -type f -name 'minecraft-*.tar.zst' \
            -mtime +${toString (cfg.backupRetentionDays - 1)} -delete
          echo "Created $archive"
        '';
        serviceConfig = {
          Type = "oneshot";
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };

      systemd.timers.minecraft-backup = {
        description = "Daily Minecraft backup schedule";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 04:30:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
          Unit = "minecraft-backup.service";
        };
      };
    })
  ];
}
