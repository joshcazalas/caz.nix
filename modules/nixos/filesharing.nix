{
  settings,
  ...
}:
let
  dataMount = settings.server.dataMount;
in
{
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = settings.server.hostName;
        "netbios name" = settings.server.hostName;
        security = "user";
        "map to guest" = "never";
      };
      media = {
        path = "${dataMount}/media";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "@media";
      };
      files = {
        path = "${dataMount}/shares";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0664";
        "directory mask" = "2775";
        "valid users" = "@media";
      };
    };
  };

  systemd.services.samba-smbd = {
    requires = [ "homelab-data-directories.service" ];
    after = [ "homelab-data-directories.service" ];
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };
}
