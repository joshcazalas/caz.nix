{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.releaseUpdater;
  updater = pkgs.writeShellApplication {
    name = "caz-stage-server-release";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.curl
      pkgs.gh
      pkgs.gnugrep
      pkgs.gawk
      pkgs.jq
      pkgs.nixos-rebuild
      pkgs.snzip
      pkgs.util-linux
    ];
    text = builtins.readFile ../../scripts/stage-server-release.sh;
  };
in
{
  options.homelab.releaseUpdater = {
    enable = lib.mkEnableOption "verified, staged-only caz.nix release updates";

    repository = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
      default = "joshcazalas/caz.nix";
      description = "Public GitHub repository that publishes trusted caz.nix releases.";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 04:00:00";
      description = "systemd calendar expression controlling release checks.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "2h";
      description = "Stable randomized delay applied to scheduled release checks.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ updater ];

    systemd.services.caz-release-updater = {
      description = "Verify and stage the latest caz.nix homeserver release";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

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
        UMask = "0077";

        # This unit must update the NixOS system profile and bootloader, so it
        # intentionally remains a root service. These settings still remove
        # access it does not need for downloading, verifying, and staging.
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
      description = "Check for a new caz.nix homeserver release";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        FixedRandomDelay = true;
        Unit = "caz-release-updater.service";
      };
    };
  };
}
