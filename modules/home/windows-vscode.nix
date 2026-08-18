{
  config,
  lib,
  ...
}:
let
  cfg = config.caz.windows.vscode;
  windowsScript = "${config.xdg.dataHome}/caz/windows-vscode.ps1";
  extensionsFile = "${config.xdg.configHome}/caz/windows-vscode-extensions.json";
  powershell = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe";
  wslpath = "/usr/bin/wslpath";
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
      # Home Manager replaces PATH with a Nix-only activation environment, so
      # host and Windows interoperability tools must use their absolute paths.
      powershell_bin=${lib.escapeShellArg powershell}
      wslpath_bin=${lib.escapeShellArg wslpath}

      if [[ ! -x "$powershell_bin" ]]; then
        echo "Windows VS Code setup requires WSL interoperability at $powershell_bin." >&2
        exit 1
      fi
      if [[ ! -x "$wslpath_bin" ]]; then
        echo "Windows VS Code setup requires the WSL utility at $wslpath_bin." >&2
        exit 1
      fi

      windows_script="$("$wslpath_bin" -w ${lib.escapeShellArg windowsScript})"
      extensions_file="$("$wslpath_bin" -w ${lib.escapeShellArg extensionsFile})"
      run "$powershell_bin" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$windows_script" -ExtensionsFile "$extensions_file"
    '';
  };
}
