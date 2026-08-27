{
  description = "Josh's NixOS homelab and Home Manager configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    auxide.url = "github:joshcazalas/auxide";
  };

  outputs =
    inputs@{
      self,
      auxide,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      sops-nix,
      ...
    }:
    let
      system = "x86_64-linux";
      settings = import ./settings.nix;
      pkgs = nixpkgs.legacyPackages.${system};
      unstablePkgs = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      specialArgs = {
        inherit inputs settings unstablePkgs;
      };
      qualityPackages = with pkgs; [
        actionlint
        deadnix
        gitleaks
        jq
        nil
        nixfmt
        shellcheck
        statix
      ];
      wslHome = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = specialArgs;
        modules = [ ./hosts/cazpc/home.nix ];
      };
      wslSshSettings = wslHome.config.programs.ssh.settings;
      homeserver = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = [
          sops-nix.nixosModules.sops
          auxide.nixosModules.default
          home-manager.nixosModules.home-manager
          ./hosts/homeserver
        ];
      };
    in
    {
      formatter.${system} = pkgs.nixfmt-tree;

      packages.${system}.home-manager = home-manager.packages.${system}.home-manager;
      apps.${system}.home-manager = {
        type = "app";
        program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
      };

      devShells.${system} = {
        default = pkgs.mkShell {
          packages =
            qualityPackages
            ++ (with pkgs; [
              age
              sops
            ]);
        };

        release = pkgs.mkShell {
          packages = qualityPackages ++ [ pkgs.sbomnix ];
        };
      };

      homeConfigurations = {
        # `@wsl` is the portable profile name. Keep `@cazpc` as a compatible
        # alias for commands already documented or used on this laptop.
        "${settings.user.name}@wsl" = wslHome;
        "${settings.user.name}@cazpc" = wslHome;
      };

      nixosConfigurations.${settings.server.hostName} = homeserver;

      checks.${system} = {
        homeserver = self.nixosConfigurations.${settings.server.hostName}.config.system.build.toplevel;
        wsl-home = self.homeConfigurations."${settings.user.name}@wsl".activationPackage;
        wsl-vscode-activation = pkgs.runCommand "check-wsl-vscode-activation" { } ''
          activation=${wslHome.activationPackage}/activate

          grep -Fqx 'powershell_bin=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe' "$activation"
          grep -Fqx 'wslpath_bin=/usr/bin/wslpath' "$activation"
          grep -Fq 'run "$powershell_bin"' "$activation"

          if grep -Fq 'command -v powershell.exe' "$activation" \
            || grep -Fq 'command -v wslpath' "$activation"; then
            echo "Windows VS Code activation must not resolve interoperability tools through its Nix-only PATH." >&2
            exit 1
          fi

          touch "$out"
        '';
        wsl-ssh-activation = pkgs.runCommand "check-wsl-ssh-activation" { } ''
          activation=${wslHome.activationPackage}/activate
          ssh_config=${wslHome.config.home.file.".ssh/config".source}

          test ${
            pkgs.lib.escapeShellArg (pkgs.lib.boolToString (!(wslSshSettings.homeserver.data ? HostName)))
          } = true
          test ${pkgs.lib.escapeShellArg wslSshSettings.homeserver.data.IdentityFile} = '~/.ssh/id_ed25519'
          test ${pkgs.lib.escapeShellArg wslSshSettings.homeserver.data.IdentityAgent} = none
          test ${
            pkgs.lib.escapeShellArg wslSshSettings."homeserver-remote".data.HostName
          } = ssh.${settings.public.domain}
          test ${
            pkgs.lib.escapeShellArg wslSshSettings."homeserver-remote".data.IdentityFile
          } = '~/.ssh/id_ed25519'
          test ${pkgs.lib.escapeShellArg wslSshSettings."github.com".data.IdentityFile} = '~/.ssh/id_ed25519'

          grep -Fqx 'Host homeserver' "$ssh_config"
          grep -Fqx 'Host homeserver-remote' "$ssh_config"
          grep -Fq 'config_tmp="$config_path.hm-materialized"' "$activation"
          grep -Fq '/bin/install --mode 0600 "$config_path" "$config_tmp"' "$activation"

          touch "$out"
        '';
      };
    };
}
