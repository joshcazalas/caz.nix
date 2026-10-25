{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  cfg = config.homelab.localIntegrations;
  command = pkgs.writeShellApplication {
    name = "caz-local-integrations";
    runtimeInputs = [ config.virtualisation.docker.package ];
    text = ''
      umask 077
      exec ${lib.getExe pkgs.python3} ${../../packages/device-network/local-integrations.py} --directory ${lib.escapeShellArg cfg.dataDir} "$@"
    '';
  };
in
{
  options.homelab.localIntegrations = {
    enable = lib.mkEnableOption "privately configured local integration containers";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${settings.server.dataRoot}/local-integrations";
      description = "Private Compose configuration, installation artifacts and application state.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = command;
      description = "Validation and health command for private integration containers.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "${settings.server.dataRoot}/" cfg.dataDir;
        message = "Local integrations must remain beneath the declared homelab data root.";
      }
      {
        assertion = config.virtualisation.docker.enable;
        message = "Local integrations require the shared Docker runtime.";
      }
    ];
    environment.systemPackages = [ command ];
    systemd.tmpfiles.rules = [ "d ${cfg.dataDir} 0700 root root -" ];
    systemd.services.local-integrations = {
      description = "Local integration services with private application configuration";
      wantedBy = [ "multi-user.target" ];
      # Let the foreground service retry if Docker's first boot attempt fails.
      # Requires would cancel our start job before Restart= can take effect.
      wants = [ "docker.service" ];
      after = [ "docker.service" ];
      serviceConfig = {
        ExecStart = "${lib.getExe command} start";
        ExecStop = "${lib.getExe command} stop";
        Restart = "always";
        RestartSec = 5;
        TimeoutStartSec = 120;
        TimeoutStopSec = 90;
        UMask = "0077";
      };
    };
  };
}
