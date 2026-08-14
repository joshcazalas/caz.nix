{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  cfg = config.homelab.bluemap;
  minecraftCfg = config.homelab.minecraft;
  publicCfg = settings.public;

  inherit (lib) mkIf mkOption types;

  # Fetched and hashed at build time rather than pulled by the container at
  # startup. itzg's PLUGINS/SPIGET variables download a jar on every start,
  # which is exactly the unpinned supply chain this repository avoids
  # everywhere else.
  pluginJar = pkgs.fetchurl {
    url = "https://github.com/BlueMap-Minecraft/BlueMap/releases/download/v${cfg.version}/bluemap-${cfg.version}-paper.jar";
    inherit (cfg) hash;
  };

  # Map output deliberately lives outside the Minecraft data directory. Tiles
  # are regenerable cache measured in gigabytes, and the daily backup archives
  # the data directory wholesale, so keeping them apart means backups stay
  # small without needing an exclude rule that could silently stop matching.
  stateDir = "${settings.server.dataRoot}/bluemap";
  webRoot = "${stateDir}/web";

  containerState = "/data/bluemap";
  pluginDir = "/data/plugins/BlueMap";

  # Host-side view of the same directory, so ownership can be established
  # before the container starts.
  pluginStateDir = "${minecraftCfg.dataDir}/plugins/BlueMap";

  owner = toString config.users.users.minecraft.uid;
  group = toString config.users.groups.minecraft.gid;

  # BlueMap reads HOCON. Every value below is policy rather than operational
  # state, so it is release-controlled and mounted read-only.
  coreConf = pkgs.writeText "bluemap-core.conf" ''
    accept-download: true
    data: "${containerState}/data"
    render-thread-count: ${toString cfg.renderThreads}
    update-cooldown: 60
    full-update-interval: 1440
    scan-for-mod-resources: true
    metrics: false
  '';

  # The integrated webserver has no bind-address setting; enabling it listens
  # on 0.0.0.0. Caddy serves the rendered files instead, so this stays off and
  # the host gains no additional listener.
  webserverConf = pkgs.writeText "bluemap-webserver.conf" ''
    enabled: false
    webroot: "${containerState}/web"
    port: 8100
    sse-enabled: false
  '';

  # client-decompression was added in BlueMap 5.23 specifically so a plain
  # static file server can host the webapp. Tiles are stored gzip-compressed;
  # without this the browser receives compressed bytes it will not decode.
  webappConf = pkgs.writeText "bluemap-webapp.conf" ''
    enabled: true
    webroot: "${containerState}/web"
    update-settings-file: true
    use-cookies: true
    default-to-flat-view: false
    client-decompression: true
    min-zoom-distance: 5
    max-zoom-distance: 100000
    resolution-default: 1
    hires-slider-max: 500
    hires-slider-default: 100
    hires-slider-min: 0
    lowres-slider-max: 7000
    lowres-slider-default: 2000
    lowres-slider-min: 500
  '';

  pluginConf = pkgs.writeText "bluemap-plugin.conf" ''
    live-player-markers: ${lib.boolToString cfg.livePlayerMarkers}
    hidden-game-modes: [
      "spectator"
    ]
    hide-vanished: true
    hide-invisible: true
    hide-sneaking: false
    hide-below-sky-light: 0
    hide-below-block-light: 0
    hide-different-world: false
    skin-download: ${lib.boolToString cfg.livePlayerMarkers}
    player-render-limit: ${toString cfg.playerRenderLimit}
  '';

  storageConf = pkgs.writeText "bluemap-storage-file.conf" ''
    storage-type: file
    root: "${containerState}/web/maps"
    compression: gzip
  '';

  # render-mask is the actual bounding mechanism in BlueMap 5.x. Several
  # third-party guides still reference a "render-boundaries" key, which this
  # version ignores silently, so an incorrect key here would render the whole
  # explored world instead of failing loudly.
  overworldConf = pkgs.writeText "bluemap-overworld.conf" ''
    world: "/data/world"
    dimension: "minecraft:overworld"
    name: "${cfg.mapName}"
    sorting: 0
    start-pos: { x: 0, z: 0 }
    sky-color: "#7dabff"
    void-color: "#000000"
    sky-light: 1
    ambient-light: 0
    remove-caves-below-y: 55
    cave-detection-ocean-floor: -5
    cave-detection-uses-block-light: false
    min-inhabited-time: 0
    render-mask: [
      {
        type: box
        min-x: -${toString cfg.renderRadius}
        max-x: ${toString cfg.renderRadius}
        min-z: -${toString cfg.renderRadius}
        max-z: ${toString cfg.renderRadius}
      }
    ]
    render-edges: true
    edge-light-strength: 8
    enable-perspective-view: true
    enable-flat-view: true
    enable-free-flight-view: true
    enable-hires: true
    storage: "file"
    ignore-missing-light-data: false
    marker-sets: {
    }
  '';

  hostName = "map.${publicCfg.domain}";
in
{
  options.homelab.bluemap = {
    enable = lib.mkEnableOption "BlueMap 3D web map for the Minecraft world";

    version = mkOption {
      type = types.str;
      default = "5.23";
      description = "Pinned BlueMap release. Supports Paper 26.1.1 through 26.2.";
    };

    hash = mkOption {
      type = types.str;
      default = "sha256-M5VU11ztqzVON2Z3z8cwjEmZUpFYSejimUcY5KFT1k4=";
      description = "SRI hash of the pinned Paper plugin jar.";
    };

    mapName = mkOption {
      type = types.str;
      default = "Overworld";
      description = "Display name shown in the web viewer.";
    };

    renderRadius = mkOption {
      type = types.ints.positive;
      default = 750;
      description = ''
        Half-width in blocks of the square area rendered around spawn.
        Rendered tiles are the dominant disk cost, and empty wilderness costs
        as much to store as built areas. Widening this later only costs CPU:
        tiles are regenerable, and BlueMap deletes tiles that fall outside a
        narrowed mask on its own.
      '';
    };

    renderThreads = mkOption {
      type = types.ints.positive;
      default = 2;
      description = ''
        CPU cores BlueMap may use. Rendering runs off the server thread, so
        this trades render speed against everything else on the host rather
        than against tick rate directly.
      '';
    };

    playerRenderLimit = mkOption {
      type = types.int;
      default = 3;
      description = ''
        Pause rendering while at least this many players are online. Set to -1
        to render regardless. The map is never urgent; the game is.
      '';
    };

    livePlayerMarkers = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Show live player positions and names on the map.

        Deliberately disabled. On a publicly reachable map this would publish
        friends' usernames and their in-world locations to anyone holding the
        URL, which conflicts with keeping friend usernames out of public
        artifacts. Enable it only if every player has agreed.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = minecraftCfg.enable;
        message = "BlueMap renders the Minecraft world and requires homelab.minecraft.enable.";
      }
      {
        assertion = !publicCfg.bluemap || publicCfg.domain != "example.invalid";
        message = "Set settings.public.domain before publishing BlueMap.";
      }
      {
        assertion = !publicCfg.bluemap || config.services.caddy.enable;
        message = "Public BlueMap is served by Caddy over HTTPS.";
      }
      {
        # A public map with player markers publishes usernames and positions.
        assertion = !publicCfg.bluemap || !cfg.livePlayerMarkers;
        message = ''
          Live player markers publish friends' usernames and locations on a
          publicly reachable map. Keep homelab.bluemap.livePlayerMarkers
          disabled while settings.public.bluemap is true.
        '';
      }
    ];

    # Owned by the container's user so BlueMap can write, world-readable so
    # Caddy can serve it without joining the Minecraft group. The contents are
    # published on the Internet anyway.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 ${owner} ${group} -"
      "d ${webRoot} 0755 ${owner} ${group} -"
    ]
    # Bind-mounting a file into a directory that does not exist yet makes
    # Docker create the parents as root, which leaves the container's
    # unprivileged user unable to write beside its own config files. BlueMap
    # then fails to start because it cannot create its resource-pack
    # directory. Creating these first keeps ownership correct, and systemd
    # also corrects directories a previous start already created as root.
    ++ map (path: "d ${path} 0750 ${owner} ${group} -") [
      "${minecraftCfg.dataDir}/plugins"
      pluginStateDir
      "${pluginStateDir}/maps"
      "${pluginStateDir}/storages"
      "${pluginStateDir}/packs"
    ];

    virtualisation.oci-containers.containers.minecraft.volumes = [
      "${stateDir}:${containerState}:rw"
      "${pluginJar}:/data/plugins/bluemap.jar:ro"
      "${coreConf}:${pluginDir}/core.conf:ro"
      "${webserverConf}:${pluginDir}/webserver.conf:ro"
      "${webappConf}:${pluginDir}/webapp.conf:ro"
      "${pluginConf}:${pluginDir}/plugin.conf:ro"
      "${storageConf}:${pluginDir}/storages/file.conf:ro"
      "${overworldConf}:${pluginDir}/maps/overworld.conf:ro"
    ];

    services.caddy = mkIf publicCfg.bluemap {
      enable = true;
      virtualHosts.${hostName} = {
        # Static tiles carry no credentials, but request logs would still
        # record who is looking at the map and from where.
        logFormat = "output discard";
        extraConfig = ''
          root * ${webRoot}
          file_server
        '';
      };
    };

    networking.firewall.allowedTCPPorts = mkIf publicCfg.bluemap [
      80
      443
    ];
  };
}
