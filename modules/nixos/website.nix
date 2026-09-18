{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  cfg = config.homelab.website;
  stateName = "caz-website-${cfg.mode}";
  stateDirectory = "/var/lib/${stateName}";
  updater = pkgs.callPackage ../../packages/website-updater { };
  updaterConfig = pkgs.writeText "website-updater.json" (
    builtins.toJSON (
      {
        inherit (cfg) mode retain minimumAgeDays;
        inherit stateDirectory;
        healthUrl = "http://127.0.0.1:${toString cfg.previewPort}/";
      }
      // lib.optionalAttrs (cfg.pinnedTag != null) { inherit (cfg) pinnedTag; }
    )
  );
  serve = ''
    encode zstd gzip
    @versioned path_regexp versioned ^/releases/[a-f0-9]{40}/
    handle @versioned {
      root * ${stateDirectory}/public
      header Cache-Control "public, max-age=2592000, immutable"
      file_server
    }
    handle /releases/* {
      respond 404
    }
    handle {
      root * ${stateDirectory}/current
      header Cache-Control "no-store"
      file_server
    }
  '';
in
{
  options.homelab.website = {
    enable = lib.mkEnableOption "the Factorio portfolio website";
    mode = lib.mkOption {
      type = lib.types.enum [
        "preview"
        "release"
      ];
      default = "preview";
      description = "Preview accepts explicit local bundles; release requires signed GitHub releases. Each mode has a separate state directory.";
    };
    previewPort = lib.mkOption {
      type = lib.types.port;
      default = 8088;
      description = "HTTP port bound to loopback and the server's LAN address. It is never opened globally.";
    };
    public.enable = lib.mkEnableOption "public HTTPS serving (requires signed release mode)";
    public.domain = lib.mkOption {
      type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9.-]+";
      default = "joshcazalas.com";
      description = "Public hostname, used only after public serving is explicitly enabled.";
    };
    automaticUpdates = lib.mkEnableOption "scheduled verified website updates";
    pinnedTag = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.strMatching "website-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-g[a-f0-9]{12}"
      );
      default = null;
      description = "An exact immutable release to deploy, or null for the latest release.";
    };
    retain = lib.mkOption {
      type = lib.types.ints.between 2 100;
      default = 3;
      description = "Minimum number of accepted releases to retain, in addition to current and previous.";
    };
    minimumAgeDays = lib.mkOption {
      type = lib.types.ints.between 1 365;
      default = 30;
      description = "Keep older release assets for at least this many days so open tabs continue to work.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.public.enable || cfg.mode == "release";
        message = "Unsigned website previews must never use the public HTTPS host.";
      }
      {
        assertion = !cfg.automaticUpdates || cfg.mode == "release";
        message = "Automatic website updates require signed release mode.";
      }
      {
        assertion = cfg.previewPort != 80 && cfg.previewPort != 443;
        message = "The private website listener must use a separate port.";
      }
    ];

    users.groups.caz-website = { };
    users.users.caz-website = {
      isSystemUser = true;
      group = "caz-website";
      home = stateDirectory;
    };
    users.users.caddy.extraGroups = [ "caz-website" ];
    systemd.tmpfiles.rules = [
      "d ${stateDirectory} 0750 caz-website caz-website -"
      "d ${stateDirectory}/public 0750 caz-website caz-website -"
      "d ${stateDirectory}/public/releases 0750 caz-website caz-website -"
    ];
    environment.systemPackages = [ updater ];
    environment.etc."website-updater.json".source = updaterConfig;

    services.caddy = {
      enable = true;
      virtualHosts = {
        "http://:${toString cfg.previewPort}" = {
          logFormat = "output discard";
          extraConfig = ''
            bind 127.0.0.1 ${settings.server.lanAddress}
            ${serve}
          '';
        };
      }
      // lib.optionalAttrs cfg.public.enable {
        ${cfg.public.domain} = {
          logFormat = "output discard";
          extraConfig = serve;
        };
      };
    };
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.public.enable [
      80
      443
    ];

    systemd.services.caz-website-updater = {
      description = "Verify and atomically deploy the portfolio website";
      after = [
        "network-online.target"
        "caddy.service"
      ];
      wants = [ "network-online.target" ];
      environment = {
        HOME = stateDirectory;
        XDG_CACHE_HOME = "/var/cache/${stateName}";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "caz-website";
        Group = "caz-website";
        ExecStart = "${lib.getExe updater} --config ${updaterConfig} update";
        StateDirectory = stateName;
        StateDirectoryMode = "0750";
        CacheDirectory = stateName;
        UMask = "0027";
        TimeoutStartSec = "10min";
        MemoryMax = "512M";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        CapabilityBoundingSet = "";
      };
    };
    systemd.timers.caz-website-updater = lib.mkIf cfg.automaticUpdates {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        RandomizedDelaySec = "5min";
        Persistent = true;
        Unit = "caz-website-updater.service";
      };
    };
  };
}
