{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.caz.shell;
in
{
  options.caz.shell.blesh.enable = lib.mkEnableOption ''
    ble.sh's Fish-like autosuggestions and syntax-aware line editor
  '';

  options.caz.shell.fonts.enable = lib.mkEnableOption ''
    Meslo LG Nerd Font for graphical applications running inside Linux
  '';

  config = {
    programs.bash = {
      enable = true;
      enableCompletion = true;
      historyControl = [
        "erasedups"
        "ignorespace"
      ];
      historySize = 100000;
      historyFileSize = 200000;
    };

    programs.atuin = {
      enable = true;
      # Atuin detects and uses ble.sh when it is loaded. Home Manager's normal
      # integration remains the fallback when the experimental editor is off.
      enableBashIntegration = !cfg.blesh.enable;
      flags = [ "--disable-ai" ];
      forceOverwriteSettings = true;
      settings = {
        ai.enabled = false;
        auto_sync = false;
        enter_accept = false;
        filter_mode_shell_up_key_binding = "directory";
        search_mode = "fuzzy";
        update_check = false;
      };
    };

    programs.fzf = {
      enable = true;
      # ble.sh requires its own fzf bridge. Its module below supplies that
      # bridge when enabled; otherwise use fzf's standard Bash integration.
      enableBashIntegration = !cfg.blesh.enable;
      defaultCommand = "${pkgs.fd}/bin/fd --type f --hidden --follow --exclude .git";
      fileWidgetCommand = "${pkgs.fd}/bin/fd --type f --hidden --follow --exclude .git";
      changeDirWidgetCommand = "${pkgs.fd}/bin/fd --type d --hidden --follow --exclude .git";
      defaultOptions = [
        "--height=40%"
        "--layout=reverse"
        "--border"
        "--info=inline"
      ];
    };

    programs.starship = {
      enable = true;
      enableBashIntegration = true;
      settings = builtins.fromTOML (builtins.readFile ./starship-gruvbox-rainbow.toml);
    };

    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
    };

    fonts.fontconfig.enable = cfg.fonts.enable;

    home.packages =
      lib.optionals cfg.blesh.enable [ pkgs.blesh ]
      ++ lib.optionals cfg.fonts.enable [ pkgs.nerd-fonts.meslo-lg ];

    xdg.configFile."nix/nix.conf".text = ''
      experimental-features = nix-command flakes
    '';

    # ble.sh is intentionally isolated in this conditional block. Set
    # `caz.shell.blesh.enable = false` and switch again to return to Readline
    # while keeping Atuin, fzf, Starship, and zoxide.
    programs.bash.bashrcExtra = lib.mkIf cfg.blesh.enable ''
      if [[ $- == *i* ]]; then
        source -- "${pkgs.blesh}/share/blesh/ble.sh" --attach=none
      fi
    '';

    xdg.configFile."blesh/init.sh" = lib.mkIf cfg.blesh.enable {
      text = ''
        # Fish-like ghost suggestions are enabled by default on Bash 4+.
        bleopt complete_auto_delay=200
        ble-face -s auto_complete fg=242

        # Prefer a quiet terminal over an audible bell.
        bleopt edit_bell=
      '';
    };

    programs.bash.initExtra = lib.mkIf cfg.blesh.enable (
      lib.mkMerge [
        (lib.mkOrder 500 ''
          # The stock fzf bindings are not compatible with ble.sh. These are
          # the integration modules maintained by ble.sh upstream.
          ble-import integration/fzf-completion
          ble-import integration/fzf-key-bindings
        '')
        (lib.mkOrder 600 ''
          # Load after fzf so Atuin owns Ctrl-R and Up Arrow.
          eval "$(${lib.getExe pkgs.atuin} init bash --disable-ai)"
        '')
        (lib.mkOrder 10000 ''
          # Upstream recommends attaching only after the rest of .bashrc.
          [[ ! ''${BLE_VERSION-} ]] || ble-attach
        '')
      ]
    );
  };
}
