{
  config,
  lib,
  settings,
  ...
}:
let
  privateIPv4Ranges = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
in
{
  networking.firewall.allowedTCPPorts = lib.optionals settings.public.ssh config.services.openssh.ports;

  # The first ban lasts one hour. Repeat offenders are banned progressively
  # longer, up to one week, across both SSH and public application jails.
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    ignoreIP = privateIPv4Ranges;
    bantime-increment = {
      enable = true;
      multipliers = "1 2 4 8 16 32 64 128";
      maxtime = "168h";
      overalljails = true;
    };

    jails = {
      DEFAULT.settings.findtime = "10m";

      # NixOS supplies and enables the standard sshd jail automatically when
      # both OpenSSH and Fail2ban are enabled. Keep its policy explicit here.
      sshd.settings = {
        maxretry = 5;
        findtime = "10m";
        bantime = "1h";
      };

      # Jellyfin logs the real source only when Caddy's loopback address is in
      # Dashboard > Networking > Known proxies. This follows Jellyfin's
      # documented pattern, using Fail2ban 1.1.0's <HOST> failure identity in
      # place of the newer bare <ADDR> token.
      jellyfin = lib.mkIf settings.public.jellyfin {
        filter.Definition.failregex = ''
          ^.*Authentication request for .* has been denied \(IP: "<HOST>"\)\.
        '';
        settings = {
          backend = "auto";
          port = "http,https";
          logpath = "${config.services.jellyfin.logDir}/log_*.log";
          maxretry = 5;
          findtime = "10m";
          bantime = "1h";
        };
      };
    };
  };

  # Jellyfin rotates to a newly named log each day. Reloading the jail after
  # rotation makes Fail2ban follow the new file without restarting Jellyfin.
  systemd.services.fail2ban-jellyfin-reload = lib.mkIf settings.public.jellyfin {
    description = "Reload the Fail2ban Jellyfin jail after log rotation";
    after = [ "fail2ban.service" ];
    requires = [ "fail2ban.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe' config.services.fail2ban.package "fail2ban-client"} reload jellyfin";
    };
  };

  systemd.timers.fail2ban-jellyfin-reload = lib.mkIf settings.public.jellyfin {
    description = "Daily reload of the Fail2ban Jellyfin jail";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00:45:00";
      Persistent = true;
      Unit = "fail2ban-jellyfin-reload.service";
    };
  };

  assertions = [
    {
      assertion =
        !settings.public.ssh
        || (
          config.services.openssh.enable
          && config.services.openssh.settings.AuthenticationMethods == "publickey"
          && config.services.openssh.settings.PasswordAuthentication == false
          && config.services.openssh.settings.KbdInteractiveAuthentication == false
          && config.services.openssh.settings.PermitRootLogin == "no"
          && config.services.fail2ban.enable
        );
      message = "Public SSH requires key-only OpenSSH and Fail2ban.";
    }
    {
      assertion =
        !settings.public.jellyfin
        || (
          config.services.caddy.enable
          &&
            config.services.caddy.virtualHosts."jellyfin.${settings.public.domain}".logFormat
            == "output discard"
          && config.services.fail2ban.jails.jellyfin.enabled
        );
      message = "Public Jellyfin requires HTTPS proxying without request logs and an active Fail2ban jail.";
    }
  ];
}
