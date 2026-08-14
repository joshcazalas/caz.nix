{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.monitoring;

  inherit (lib)
    concatStringsSep
    mkIf
    mkOption
    optionals
    types
    ;

  loopback = "127.0.0.1";

  # Auxide already publishes Prometheus exposition format on 9090, so the
  # Prometheus server itself must not take its default port on this host.
  prometheusPort = 9095;
  alertmanagerPort = 9093;
  alertmanagerClusterPort = 9094;
  nodePort = 9100;
  smartctlPort = 9633;
  grafanaPort = 3001; # 3000 belongs to the AdGuard Home administration UI.

  secretNames = {
    alertEnvironment = "monitoring/alerting";
    grafanaPassword = "monitoring/grafanaAdminPassword";
    grafanaSecretKey = "monitoring/grafanaSecretKey";
  };

  target = port: "${loopback}:${toString port}";

  scrapeJob = name: port: {
    job_name = name;
    static_configs = [ { targets = [ (target port) ]; } ];
  };

  # Every alert reaches the same operator, so a single receiver carries both
  # transports. Losing one channel must not silence the other.
  primaryReceiver = {
    name = "operator";
    email_configs = [
      {
        to = "\${ALERT_EMAIL_TO}";
        from = "\${ALERT_EMAIL_FROM}";
        smarthost = cfg.smtpSmarthost;
        auth_username = "\${SMTP_USERNAME}";
        auth_password = "\${SMTP_PASSWORD}";
        require_tls = true;
        send_resolved = true;
        headers.subject = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} on {{ .CommonLabels.instance }}";
      }
    ];
    discord_configs = [
      {
        webhook_url = "\${DISCORD_WEBHOOK_URL}";
        send_resolved = true;
      }
    ];
  };

  # The watchdog must never reach a human channel. Its only job is to keep an
  # off-site check fed so that silence itself becomes an alert.
  deadManSwitchReceiver = {
    name = "dead-man-switch";
    webhook_configs = [
      {
        url = "\${HEALTHCHECK_URL}";
        send_resolved = false;
      }
    ];
  };

  alertmanagerConfiguration = {
    global.resolve_timeout = "5m";

    route = {
      receiver = primaryReceiver.name;
      group_by = [
        "alertname"
        "instance"
      ];
      group_wait = "30s";
      group_interval = "5m";
      repeat_interval = "4h";
      routes = optionals cfg.deadManSwitch.enable [
        {
          receiver = deadManSwitchReceiver.name;
          matchers = [ "alertname=\"Watchdog\"" ];
          group_wait = "0s";
          group_interval = "1m";
          # Must stay comfortably below the grace period configured on the
          # external check, or a healthy system will look dead.
          repeat_interval = cfg.deadManSwitch.pingInterval;
        }
      ];
    };

    # A failing disk produces both warnings and criticals. Page once.
    inhibit_rules = [
      {
        source_matchers = [ "severity=\"critical\"" ];
        target_matchers = [ "severity=\"warning\"" ];
        equal = [
          "alertname"
          "instance"
        ];
      }
    ];

    receivers = [
      primaryReceiver
    ]
    ++ optionals cfg.deadManSwitch.enable [ deadManSwitchReceiver ];
  };

  # `amtool check-config` cannot validate a file that still contains envsubst
  # placeholders, so the module's own checkConfig is disabled. Validating a
  # dummy-substituted copy at build time restores that safety net without
  # putting a real credential in the Nix store. system.extraDependencies forces
  # this to build with the system closure, so CI fails on a malformed route.
  validatedAlertmanagerConfig =
    pkgs.runCommand "alertmanager-config-check"
      {
        # The same envsubst implementation the NixOS unit uses at preStart, so
        # this check exercises the real substitution behaviour.
        nativeBuildInputs = [
          config.services.prometheus.alertmanager.package
          pkgs.envsubst
        ];
        configuration = builtins.toJSON alertmanagerConfiguration;
        passAsFile = [ "configuration" ];
      }
      ''
        export ALERT_EMAIL_TO="alerts@example.invalid"
        export ALERT_EMAIL_FROM="alerts@example.invalid"
        export SMTP_USERNAME="alerts@example.invalid"
        export SMTP_PASSWORD="placeholder"
        export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/0/placeholder"
        export HEALTHCHECK_URL="https://hc.example.invalid/placeholder"

        envsubst -o config.json < "$configurationPath"
        amtool check-config config.json
        touch "$out"
      '';

  overviewDashboard = builtins.toJSON (import ./monitoring-dashboard.nix);

  dashboardDirectory = pkgs.writeTextDir "homeserver-overview.json" overviewDashboard;
in
{
  options.homelab.monitoring = {
    enable = lib.mkEnableOption "Prometheus monitoring, alerting, and dashboards";

    retentionTime = mkOption {
      type = types.str;
      default = "90d";
      description = ''
        How long Prometheus keeps samples. Bounded deliberately: the metrics
        database lives on the root NVMe alongside every other service.
      '';
    };

    retentionSize = mkOption {
      type = types.str;
      default = "8GB";
      description = "Hard ceiling on the metrics database, whichever limit is reached first.";
    };

    scrapeInterval = mkOption {
      type = types.str;
      default = "30s";
      description = "Default scrape interval. Longer intervals trade resolution for disk.";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "10.0.0.20" ];
      description = ''
        Private IPv4 addresses of other homelab hosts that run this same stack.
        Populating this turns the single host into a mutually monitoring pair:
        each host scrapes the other's exporters and the Alertmanagers gossip so
        a notification still leaves the house when one machine dies.

        Peer monitoring covers uncorrelated failures only. A power cut, router
        failure, or ISP outage takes down every host at once, which is why the
        dead man's switch below is a separate control rather than a fallback.
      '';
    };

    smtpSmarthost = mkOption {
      type = types.str;
      default = "smtp.gmail.com:587";
      description = ''
        SMTP submission endpoint. Deliberately not a secret so the delivery path
        stays reviewable; the mailbox and credential come from sops-nix.
      '';
    };

    diskWarnPercent = mkOption {
      type = types.ints.between 1 99;
      default = 15;
      description = "Free-space percentage below which a filesystem warns.";
    };

    diskCriticalPercent = mkOption {
      type = types.ints.between 1 99;
      default = 7;
      description = "Free-space percentage below which a filesystem alerts as critical.";
    };

    temperatureWarnCelsius = mkOption {
      type = types.ints.between 40 110;
      default = 80;
      description = "Sustained hardware temperature that should raise an alert.";
    };

    diskTemperatureWarnCelsius = mkOption {
      type = types.ints.between 30 90;
      default = 60;
      description = "Sustained drive temperature that should raise an alert.";
    };

    deadManSwitch = {
      enable = lib.mkEnableOption "external dead man's switch heartbeat" // {
        default = true;
      };

      pingInterval = mkOption {
        type = types.str;
        default = "5m";
        description = ''
          How often the always-firing Watchdog alert is delivered to the
          external check. The check's own grace period must be longer than this
          or a healthy system will be reported as dead.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.diskCriticalPercent < cfg.diskWarnPercent;
        message = "The critical disk threshold must be lower than the warning threshold.";
      }
      {
        assertion = config.services.grafana.settings.server.http_addr == loopback;
        message = ''
          Grafana must stay bound to loopback and be reached through SSH local
          forwarding. Publishing a dashboard to the LAN needs a network-policy
          review first.
        '';
      }
      {
        assertion = config.services.prometheus.listenAddress == loopback;
        message = "Prometheus must stay bound to loopback.";
      }
      {
        assertion = config.services.prometheus.alertmanager.listenAddress == loopback;
        message = "Alertmanager must stay bound to loopback.";
      }
      {
        assertion = !lib.hasInfix "$__env{" config.services.grafana.settings.security.admin_password;
        message = "The Grafana administrator password must come from a file, never the environment.";
      }
      {
        assertion = config.services.prometheus.alertmanager.environmentFile != null;
        message = ''
          Alertmanager credentials must be supplied through an environment file
          so that no mailbox, webhook, or password reaches the Nix store.
        '';
      }
      {
        assertion = !config.services.beszel.hub.enable;
        message = "Beszel was replaced by the Prometheus stack; remove the leftover hub.";
      }
    ];

    # Forces the dummy-substituted Alertmanager config to build, turning a
    # malformed route or receiver into a CI failure instead of a silent
    # notification outage discovered during an incident.
    system.extraDependencies = [ validatedAlertmanagerConfig ];

    sops.secrets.${secretNames.grafanaPassword} = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/grafanaAdminPassword";
      owner = "grafana";
      restartUnits = [ "grafana.service" ];
    };

    # Grafana encrypts datasource credentials in its own database with this
    # key. Nothing sensitive is stored there today, but 26.05 removed the
    # shared default because a predictable key made that encryption useless.
    sops.secrets.${secretNames.grafanaSecretKey} = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/grafanaSecretKey";
      owner = "grafana";
      restartUnits = [ "grafana.service" ];
    };

    sops.secrets."monitoring/alertEmailTo" = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/alertEmailTo";
    };
    sops.secrets."monitoring/alertEmailFrom" = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/alertEmailFrom";
    };
    sops.secrets."monitoring/smtpUsername" = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/smtpUsername";
    };
    sops.secrets."monitoring/smtpPassword" = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/smtpPassword";
    };
    sops.secrets."monitoring/discordWebhookUrl" = {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/discordWebhookUrl";
    };
    sops.secrets."monitoring/healthcheckUrl" = mkIf cfg.deadManSwitch.enable {
      sopsFile = ../../secrets/homeserver.yaml;
      key = "monitoring/healthcheckUrl";
    };

    # systemd reads EnvironmentFile as the service manager before Alertmanager's
    # DynamicUser exists, so root ownership is both correct and the tightest
    # available. The rendered file never enters the Nix store.
    sops.templates.${secretNames.alertEnvironment} = {
      mode = "0400";
      restartUnits = [ "alertmanager.service" ];
      content = concatStringsSep "\n" (
        [
          "ALERT_EMAIL_TO=${config.sops.placeholder."monitoring/alertEmailTo"}"
          "ALERT_EMAIL_FROM=${config.sops.placeholder."monitoring/alertEmailFrom"}"
          "SMTP_USERNAME=${config.sops.placeholder."monitoring/smtpUsername"}"
          "SMTP_PASSWORD=${config.sops.placeholder."monitoring/smtpPassword"}"
          "DISCORD_WEBHOOK_URL=${config.sops.placeholder."monitoring/discordWebhookUrl"}"
        ]
        ++ optionals cfg.deadManSwitch.enable [
          "HEALTHCHECK_URL=${config.sops.placeholder."monitoring/healthcheckUrl"}"
        ]
      );
    };

    services.prometheus = {
      enable = true;
      listenAddress = loopback;
      port = prometheusPort;
      inherit (cfg) retentionTime;

      # promtool validates every alerting rule while the system builds, so a
      # rule that could never fire fails CI rather than failing an incident.
      checkConfig = true;

      extraFlags = [
        "--storage.tsdb.retention.size=${cfg.retentionSize}"
      ];

      globalConfig = {
        scrape_interval = cfg.scrapeInterval;
        evaluation_interval = cfg.scrapeInterval;
        external_labels.host = config.networking.hostName;
      };

      alertmanagers = [
        {
          static_configs = [
            {
              targets = [
                (target alertmanagerPort)
              ]
              ++ map (peer: "${peer}:${toString alertmanagerPort}") cfg.peers;
            }
          ];
        }
      ];

      scrapeConfigs = [
        (scrapeJob "prometheus" prometheusPort)
        (scrapeJob "node" nodePort)
        (scrapeJob "smartctl" smartctlPort)
        (scrapeJob "alertmanager" alertmanagerPort)
        (scrapeJob "grafana" grafanaPort)
      ]
      # Auxide already speaks the Prometheus exposition format on its private
      # listener, so it joins the same alerting pipeline for free once enabled.
      ++ optionals config.services.auxide.enable [
        {
          job_name = "auxide";
          metrics_path = "/metrics";
          static_configs = [ { targets = [ "${loopback}:9090" ]; } ];
        }
      ]
      ++ optionals (cfg.peers != [ ]) [
        {
          job_name = "peer-node";
          static_configs = [
            { targets = map (peer: "${peer}:${toString nodePort}") cfg.peers; }
          ];
        }
        {
          job_name = "peer-smartctl";
          static_configs = [
            { targets = map (peer: "${peer}:${toString smartctlPort}") cfg.peers; }
          ];
        }
      ];

      exporters = {
        node = {
          enable = true;
          listenAddress = loopback;
          port = nodePort;
          enabledCollectors = [
            "systemd"
            "processes"
          ];
          extraFlags = [
            # Unit failure is the single most useful signal here: it covers
            # backups, deployments, and every service in one rule. Device,
            # slice, scope, and mount units add cardinality without adding
            # anything the filesystem collector does not already report.
            "--collector.systemd.unit-exclude=.+\\.(device|slice|scope|mount|swap)"
          ];
        };

        smartctl = {
          enable = true;
          listenAddress = loopback;
          port = smartctlPort;
          # Autodiscovery keeps this correct when the spare SSD is installed.
          devices = [ ];
          maxInterval = "5m";
        };
      };
    };

    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = loopback;
      port = alertmanagerPort;
      configuration = alertmanagerConfiguration;
      environmentFile = config.sops.templates.${secretNames.alertEnvironment}.path;
      clusterPeers = cfg.peers;

      # Placeholders are not valid URLs or addresses, so the module's own check
      # cannot run here. validatedAlertmanagerConfig performs the same check
      # against a dummy-substituted copy instead.
      checkConfig = false;

      extraFlags = optionals (cfg.peers != [ ]) [
        "--cluster.listen-address=0.0.0.0:${toString alertmanagerClusterPort}"
      ];
    };

    services.grafana = {
      enable = true;

      settings = {
        server = {
          http_addr = loopback;
          http_port = grafanaPort;
          # Correct links in alert notifications even though the UI itself is
          # only reachable through an SSH tunnel.
          root_url = "http://${loopback}:${toString grafanaPort}/";
        };

        security = {
          admin_user = "admin";
          admin_password = "$__file{${config.sops.secrets.${secretNames.grafanaPassword}.path}}";
          secret_key = "$__file{${config.sops.secrets.${secretNames.grafanaSecretKey}.path}}";
          cookie_secure = false;
          disable_gravatar = true;
        };

        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
        };

        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
      };

      provision = {
        enable = true;

        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              # The provisioned dashboard references this uid directly.
              uid = "homelab-prometheus";
              access = "proxy";
              url = "http://${target prometheusPort}";
              isDefault = true;
            }
          ];
        };

        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "homelab";
              type = "file";
              disableDeletion = true;
              allowUiUpdates = false;
              options.path = dashboardDirectory;
            }
          ];
        };
      };
    };

    # smartd still schedules the self-tests; smartctl_exporter only reads the
    # results they produce. Without a schedule the exporter reports a health
    # summary that no longer reflects the surface of the disk.
    services.smartd = {
      enable = true;
      autodetect = true;
      extraOptions = [ "--interval=1800" ];
      defaults.autodetected = "-a -o on -S on -s (S/../.././02|L/../01/./03)";
    };
  };
}
