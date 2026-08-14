{
  config,
  settings,
  ...
}:
let
  sshDir = "${config.home.homeDirectory}/.ssh";
in
{
  # Private keys stay encrypted at rest, which leaves them unusable anywhere
  # there is no terminal to prompt at: editors, hooks, and scripted tooling all
  # fail with "Permission denied (publickey)". A user agent resolves that by
  # holding each key after a single unlock per login.
  services.ssh-agent.enable = true;

  programs.ssh = {
    enable = true;

    # Upstream is retiring this implicit default set, so declare what this
    # profile actually wants instead of inheriting values silently.
    enableDefaultConfig = false;

    settings = {
      "*" = {
        # Send only the key a host is configured for. Otherwise every
        # connection advertises every public key on the machine before
        # authenticating, which tells each host what else we hold.
        IdentitiesOnly = true;

        # Unlock a key once, then reuse it from the agent for the rest of the
        # login instead of prompting on every push or connection.
        AddKeysToAgent = "yes";

        ServerAliveInterval = 60;
      };

      # A credential that only ever needs to push code should not also open a
      # shell on a publicly reachable server, so GitHub gets a key of its own.
      "github.com" = {
        User = "git";
        IdentityFile = "${sshDir}/id_ed25519_github";
      };

      # Remote administration keeps the original key: the one published as
      # settings.user.sshPublicKey and installed into the server's
      # authorized_keys by modules/nixos/base.nix.
      "ssh.${settings.public.domain}" = {
        User = settings.user.name;
        IdentityFile = "${sshDir}/id_ed25519";
      };
    };
  };
}
