{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.factorio;
  stateDir = "/var/lib/${cfg.stateDirName}";
  backupDir = "/var/backup/factorio";
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
  # The headless distribution includes the official expansion. State this
  # explicitly so package updates cannot silently change the world's content.
  modList = pkgs.writeText "factorio-mod-list.json" (
    builtins.toJSON {
      mods =
        map
          (name: {
            inherit name;
            enabled = true;
          })
          [
            "base"
            "quality"
            "elevated-rails"
            "space-age"
          ];
    }
  );
in
{
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
        message = "This initial Factorio setup manages the Space Age mod list; integrate custom mods explicitly before setting services.factorio.mods.";
      }
    ];

    environment.systemPackages = [ administration ];
    systemd.tmpfiles.rules = [
      "d ${backupDir} 0700 root root -"
      "d /run/caz-container-maintenance 0700 root root -"
    ];

    systemd.services.factorio = {
      # Runs as upstream's DynamicUser, before upstream map creation.
      preStart = lib.mkBefore ''
        ${lib.getExe pkgs.python3} ${../../scripts/factorio-admin.py} \
          --state-dir ${lib.escapeShellArg stateDir} initialize
        mkdir -p ${lib.escapeShellArg "${stateDir}/mods"}
        cp ${modList} ${lib.escapeShellArg "${stateDir}/mods/mod-list.json"}
        chmod 0600 ${lib.escapeShellArg "${stateDir}/mods/mod-list.json"}
      '';
      serviceConfig = {
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
