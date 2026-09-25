{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.factorio;
  content = config.homelab.factorio;
  stateDir = "/var/lib/${cfg.stateDirName}";
  backupDir = "/var/backup/factorio";
  manifest = builtins.fromJSON (builtins.readFile content.modManifest);
  modDir = "${stateDir}/mod-sets/${builtins.hashString "sha256" (builtins.toJSON manifest)}";
  mapGenSettings = pkgs.writeText "factorio-map-gen-settings.json" (
    builtins.toJSON content.mapGenSettings
  );
  administration = pkgs.writeShellApplication {
    name = "factorio-access";
    runtimeInputs = [
      pkgs.systemd
      pkgs.gnutar
      pkgs.zstd
      pkgs.iproute2
    ];
    text = ''
      exec ${lib.getExe pkgs.python3} ${../../scripts/factorio-admin.py} \
        --state-dir ${lib.escapeShellArg stateDir} \
        --backup-dir ${backupDir} --port ${toString cfg.port} "$@"
    '';
  };
in
{
  options.homelab.factorio = {
    modManifest = lib.mkOption {
      type = lib.types.path;
      default = ./factorio-mods.json;
      description = "Pinned mod archives, portal download paths, and SHA-256 checksums.";
    };
    world = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      default = "modded-space-age-v1";
      description = "Persistent world identity. Changing this selects or creates a different world.";
    };
    mapGenSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Map generation settings applied only when creating a new world.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "factorio-headless";

    services.factorio = {
      game-name = "caz Space Age";
      description = "Private Space Age server";
      # Visibility controls discovery, not whether friends can connect by DNS.
      public = false;
      lan = false;
      requireUserVerification = true;
      autosave-interval = 10;
      loadLatestSave = true;
      extraSettings = {
        max_players = 10;
        auto_pause = true;
        autosave_slots = 5;
      };
      # Keep these lists writable and outside the release/Nix store.
      extraArgs = [
        "--mod-directory=${modDir}"
        "--use-server-whitelist=true"
        "--server-whitelist=${stateDir}/server-whitelist.json"
        "--server-adminlist=${stateDir}/server-adminlist.json"
        "--server-banlist=${stateDir}/server-banlist.json"
      ];
    };

    assertions = [
      {
        assertion = cfg.allowedPlayers == [ ] && cfg.admins == [ ];
        message = "Factorio membership is runtime state; use sudo factorio-access instead of Nix player lists.";
      }
      {
        assertion = cfg.requireUserVerification && !(cfg.extraSettings ? require_user_verification);
        message = "Factorio whitelist identities must be verified by Factorio.com.";
      }
      {
        assertion = cfg.mods == [ ] && cfg.mods-dat == null;
        message = "Use homelab.factorio.modManifest for authenticated, pinned mods; do not mix it with services.factorio.mods or mods-dat.";
      }
    ];

    environment.systemPackages = [ administration ];
    sops.secrets."factorio/mod-portal" = {
      sopsFile = ../../secrets/factorio.yaml;
      key = "modPortal";
      restartUnits = [ "factorio.service" ];
    };
    systemd.tmpfiles.rules = [
      "d ${backupDir} 0700 root root -"
      "d /run/caz-container-maintenance 0700 root root -"
    ];

    systemd.services.factorio = {
      environment.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      # Runs as upstream's DynamicUser, before upstream map creation.
      preStart = lib.mkBefore ''
        ${lib.getExe pkgs.python3} ${../../scripts/factorio-admin.py} \
          --state-dir ${lib.escapeShellArg stateDir} initialize
        ${lib.getExe pkgs.python3} ${../../scripts/factorio-prepare.py} \
          --manifest ${content.modManifest} \
          --mod-directory ${lib.escapeShellArg modDir} \
          --credentials "$CREDENTIALS_DIRECTORY/mod-portal" \
          --state-dir ${lib.escapeShellArg stateDir} \
          --world ${lib.escapeShellArg content.world} \
          --binary ${lib.getExe cfg.package} --config ${cfg.configFile} \
          --map-gen-settings ${mapGenSettings} --save-name ${lib.escapeShellArg cfg.saveName}
      '';
      serviceConfig = {
        LoadCredential = [ "mod-portal:${config.sops.secrets."factorio/mod-portal".path}" ];
        # First activation downloads about 200 MB and generates a modded map.
        TimeoutStartSec = "15min";
        StateDirectoryMode = "0700";
        UMask = lib.mkForce "0077";
        TimeoutStopSec = "180s";
        RestartSec = "10s";
        # Initial ceilings, not reservations: Minecraft shares this 8 GB host.
        MemoryHigh = "2G";
        MemoryMax = "3G";
      };
    };

    systemd.services.factorio-backup = {
      description = "Save and archive Factorio state with a brief game shutdown";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe administration} backup";
        TimeoutStartSec = "infinity";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.factorio-backup = {
      description = "Daily Factorio backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 05:00:00";
        RandomizedDelaySec = "15m";
        Persistent = true;
      };
    };
  };
}
