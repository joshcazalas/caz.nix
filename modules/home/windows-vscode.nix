{
  config,
  lib,
  ...
}:
let
  cfg = config.caz.windows.vscode;
  windowsScript = "${config.xdg.dataHome}/caz/windows-vscode.ps1";
  extensionsFile = "${config.xdg.configHome}/caz/windows-vscode-extensions.json";
in
{
  options.caz.windows.vscode = {
    enable = lib.mkEnableOption ''
      the Windows VS Code client and its WSL integration from Home Manager
    '';

    extensions = lib.mkOption {
      type = lib.types.listOf (
        lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9-]*\\.[A-Za-z0-9][A-Za-z0-9.-]*"
      );
      default = [ "ms-vscode-remote.remote-wsl" ];
      description = ''
        Windows-side VS Code extensions to ensure are installed. Extensions
        not listed here are preserved.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.dataFile."caz/windows-vscode.ps1".source = ../../bootstrap/windows-vscode.ps1;
    xdg.configFile."caz/windows-vscode-extensions.json".text = builtins.toJSON cfg.extensions;

    # VS Code's supported WSL architecture requires its graphical client and
    # WSL extension on Windows. Keep those external side effects idempotent and
    # after Home Manager has installed the managed helper and extension list.
    home.activation.windowsVSCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! command -v powershell.exe >/dev/null 2>&1; then
        echo "Windows VS Code setup requires WSL interoperability and powershell.exe." >&2
        exit 1
      fi
      if ! command -v wslpath >/dev/null 2>&1; then
        echo "Windows VS Code setup requires the WSL wslpath utility." >&2
        exit 1
      fi

      windows_script="$(wslpath -w ${lib.escapeShellArg windowsScript})"
      extensions_file="$(wslpath -w ${lib.escapeShellArg extensionsFile})"
      run powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$windows_script" -ExtensionsFile "$extensions_file"
    '';
  };
}
