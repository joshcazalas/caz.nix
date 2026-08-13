{
  config,
  lib,
  settings,
  ...
}:
let
  dataRoot = settings.server.dataRoot;
in
{
  # Shared service state intentionally stays on the root NVMe until a reliable
  # second SSD is installed. Declaring it through tmpfiles preserves ownership
  # and permissions without pretending an external /srv mount exists.
  systemd.tmpfiles.rules = [
    "d ${dataRoot} 0750 root media -"
    "d ${dataRoot}/backups 2775 root media -"
    "d ${dataRoot}/media 2775 root media -"
    "d ${dataRoot}/photos 2775 root media -"
    "d ${dataRoot}/shares 2775 root media -"
  ];

  assertions = [
    {
      assertion = lib.hasPrefix "/var/lib/" dataRoot;
      message = "settings.server.dataRoot must explicitly reside under /var/lib on the root SSD.";
    }
    {
      assertion = !builtins.hasAttr "/srv" config.fileSystems;
      message = "/srv must remain unconfigured until reliable secondary storage is installed.";
    }
  ];
}
