{ settings, ... }:
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
        IdentityFile = "~/.ssh/id_ed25519_github";
        IdentitiesOnly = true;
      };

      "homeserver" = {
        HostName = "ssh.${settings.public.domain}";
        User = settings.user.name;
        IdentityFile = "~/.ssh/id_ed25519_homeserver";
        IdentitiesOnly = true;
        # Overrides the global default deliberately: this key reaches an
        # interactive shell with sudo on an Internet-facing host, a bigger
        # blast radius than a GitHub push. Require the passphrase on every
        # connection instead of caching it in the agent.
        AddKeysToAgent = "no";
      };
    };
  };

  # Adopt the existing hand-written config on the first Home Manager switch.
  home.file.".ssh/config".force = true;
}
