{
  config,
  lib,
  settings,
  ...
}:
let
  cfg = config.homelab.homeAssistant;
in
{
  options.homelab.homeAssistant.https = {
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "ha.${settings.public.domain}";
      description = "Private DNS name used by Home Assistant clients and the TLS certificate.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "HTTPS port shared by trusted LAN clients and household WireGuard peers.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The release gate verifies the same certificate, proxy and frontend as a client.
    # It also works before the host's own DNS resolver has switched to AdGuard.
    networking.hosts."127.0.0.1" = [ cfg.https.hostName ];

    # Keep HA off the public Caddy listeners, including during certificate renewal.
    services.nginx = {
      enable = true;
      virtualHosts.${cfg.https.hostName} = {
        onlySSL = true;
        listen = [
          {
            addr = "0.0.0.0";
            inherit (cfg.https) port;
            ssl = true;
          }
        ];
        useACMEHost = cfg.https.hostName;
        extraConfig = ''
          access_log off;
          # HA owns its upload limits, including backup restoration.
          client_max_body_size 0;
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:8123";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host ${cfg.https.hostName}:${toString cfg.https.port};
            proxy_set_header X-Forwarded-Host "";
            proxy_set_header X-Forwarded-For $remote_addr;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 1h;
          '';
        };
      };
    };
  };
}
