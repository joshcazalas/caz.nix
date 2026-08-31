{
  config,
  lib,
  pkgs,
  settings,
  ...
}:
let
  serverSettings = {
    User = settings.user.name;
    IdentityFile = "~/.ssh/id_ed25519";
    IdentityAgent = "none";
    IdentitiesOnly = true;
    # This key reaches an interactive shell with sudo on an Internet-facing
    # host, a bigger blast radius than a GitHub push. Require the passphrase on
    # every connection instead of caching it in the agent.
    AddKeysToAgent = "no";
  };
in
{
  # Runs as a systemd user service against a stable socket under
  # $XDG_RUNTIME_DIR, exported as SSH_AUTH_SOCK through Home Manager's session
  # variables. Every new shell picks up the same socket automatically -- no
  # per-terminal `eval $(ssh-agent)` -- so tools like Claude Code or Codex that
  # just inherit the session environment can use an already-unlocked key
  # without a separate credential of their own.
  services.ssh-agent = {
    enable = true;
    # An identity clears from agent memory on its own after a workday instead
    # of staying decrypted for as long as this WSL session happens to stay up.
    defaultMaximumIdentityLifetime = 12 * 60 * 60;
  };

  # Ubuntu 26.04 globally enables its own ssh-agent.socket at
  # $XDG_RUNTIME_DIR/openssh_agent. It conflicts with Home Manager's service
  # of the same name and can leave systemd-launched tools pointed at a socket
  # that no process serves. Mask only that vendor socket and make the managed
  # socket authoritative for user services as well as shells.
  home.file.".config/systemd/user/ssh-agent.socket".source =
    config.lib.file.mkOutOfStoreSymlink "/dev/null";
  systemd.user.sessionVariables.SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";
  home.activation.reconcileSshAgentSocket = lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
    if ${config.systemd.user.systemctlPath} --user is-active --quiet ssh-agent.socket; then
      run ${config.systemd.user.systemctlPath} --user stop ssh-agent.socket
    fi
    run ${config.systemd.user.systemctlPath} --user set-environment SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent"
  '';

  # Add the GitHub identity on the first local interactive shell of a WSL
  # session. ssh-add reads its passphrase from the TTY; subsequent shells use
  # -T with the public half to prove the matching identity is already usable
  # and stay silent. Remote SSH shells never trigger an unexpected prompt.
  programs.bash.initExtra = lib.mkOrder 50 ''
    caz_ssh_identity=${lib.escapeShellArg "${config.home.homeDirectory}/.ssh/id_ed25519"}
    if [[ $- == *i* && -t 0 && -z ''${SSH_CONNECTION-} && -r "$caz_ssh_identity" && -r "$caz_ssh_identity.pub" ]]; then
      if ! ${lib.getExe' pkgs.openssh "ssh-add"} -T "$caz_ssh_identity.pub" >/dev/null 2>&1; then
        ${lib.getExe' pkgs.openssh "ssh-add"} -q "$caz_ssh_identity" || true
      fi
    fi
    unset caz_ssh_identity
  '';

  programs.ssh = {
    enable = true;
    # Home Manager's implicit `programs.ssh` defaults are being phased out;
    # state them explicitly instead of quietly losing them when that default
    # flips. Confirmed against this host's /etc/ssh/ssh_config, which
    # overrides none of them -- so this is the same behavior restated, not a
    # new policy.
    enableDefaultConfig = false;

    settings = {
      "*" = {
        # The first git/ssh call against a locked key prompts once and caches
        # it in the running agent, so a manual `ssh-add` isn't strictly
        # required -- though unlocking it yourself before starting an agent
        # session avoids a passphrase prompt surfacing inside a
        # non-interactive tool call.
        AddKeysToAgent = "yes";

        ForwardAgent = false;
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };

      "github.com" = {
        HostName = "github.com";
        User = "git";
        IdentityFile = "~/.ssh/id_ed25519";
        IdentitiesOnly = true;
      };

      # Leave HostName unset so the LAN resolver receives `homeserver` exactly
      # as it did before this file was managed. The public DNS name is not
      # resolvable from the home network.
      "homeserver" = serverSettings;

      "homeserver-remote" = serverSettings // {
        HostName = "ssh.${settings.public.domain}";
      };
    };
  };

  # Adopt the existing hand-written config on the first Home Manager switch.
  home.file.".ssh/config".force = true;

  # Home Manager normally symlinks generated files into the Nix store. This
  # WSL installation exposes that store file as owned by nobody:nogroup, and
  # OpenSSH rejects a config whose resolved owner is neither this user nor
  # root. Replace only the generated symlink with identical user-owned bytes;
  # force=true above lets the next activation refresh it normally.
  home.activation.materializeSshConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    config_path=${lib.escapeShellArg "${config.home.homeDirectory}/.ssh/config"}
    config_tmp="$config_path.hm-materialized"

    if [[ -L "$config_path" ]]; then
      run ${pkgs.coreutils}/bin/install --mode 0600 "$config_path" "$config_tmp"
      run ${pkgs.coreutils}/bin/mv --force "$config_tmp" "$config_path"
    fi
  '';
}
