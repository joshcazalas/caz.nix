{
  settings,
  ...
}:
let
  dataRoot = settings.server.dataRoot;
in
{
  services.samba = {
    enable = true;
    openFirewall = false;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = settings.server.hostName;
        "netbios name" = settings.server.hostName;
        security = "user";
        "map to guest" = "never";
      };
      media = {
        path = "${dataRoot}/media";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "@media";
      };
      files = {
        path = "${dataRoot}/shares";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0664";
        "directory mask" = "2775";
        "valid users" = "@media";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = false;
  };

  services.avahi = {
    enable = true;
    openFirewall = false;
    nssmdns4 = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };
}
