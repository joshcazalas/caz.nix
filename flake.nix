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
      wslAwsSettings = wslHome.config.programs.awscli.settings;
      expectedWslAwsSettings =
        let
          region = "us-east-1";
          ssoSession = "personal-aws";
          profile = sso_account_id: sso_role_name: {
            inherit sso_account_id sso_role_name;
            sso_session = ssoSession;
            inherit region;
            output = "json";
          };
        in
        {
          "sso-session ${ssoSession}" = {
            sso_start_url = "https://d-906786c4bb.awsapps.com/start";
            sso_region = region;
            sso_registration_scopes = "sso:account:access";
          };
          "profile management" = profile "357964519547" "BootstrapAdministrator";
          "profile management-readonly" = profile "357964519547" "ReadOnly";
          "profile deployment" = profile "245459924498" "BootstrapAdministrator";
          "profile deployment-readonly" = profile "245459924498" "ReadOnly";
          "profile uat" = profile "732006412638" "BootstrapAdministrator";
          "profile uat-readonly" = profile "732006412638" "ReadOnly";
          "profile production" = profile "134604497564" "BootstrapAdministrator";
          "profile production-readonly" = profile "134604497564" "ReadOnly";
        };
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
              util-linux
              wireguard-tools
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
        game-stream-gateway = import ./tests/game-stream-gateway.nix {
          inherit pkgs;
          inherit (inputs) sops-nix;
        };
        game-stream-enrollment =
          pkgs.runCommand "game-stream-enrollment-test"
            {
              nativeBuildInputs = with pkgs; [
                coreutils
                gnugrep
                gnused
                jq
                util-linux
              ];
            }
            ''
              export TMPDIR="$TMPDIR/game-stream-enrollment"
              mkdir -p "$TMPDIR"
              ${pkgs.bash}/bin/bash ${./tests/game-stream-enrollment.sh} ${self}
              touch "$out"
            '';
        wsl-home = self.homeConfigurations."${settings.user.name}@wsl".activationPackage;
        wsl-aws-profiles = pkgs.runCommand "check-wsl-aws-profiles" { } ''
          aws_config=${wslHome.config.home.file."${wslHome.config.home.homeDirectory}/.aws/config".source}

          test ${
            pkgs.lib.escapeShellArg (pkgs.lib.boolToString (wslAwsSettings == expectedWslAwsSettings))
          } = true
          test ${
            pkgs.lib.escapeShellArg (
              pkgs.lib.boolToString (
                !(builtins.hasAttr "${wslHome.config.home.homeDirectory}/.aws/credentials" wslHome.config.home.file)
              )
            )
          } = true

          test "$(${pkgs.gnugrep}/bin/grep -c '^\[' "$aws_config")" -eq 9
          test "$(${pkgs.gnugrep}/bin/grep -c '^\[sso-session personal-aws\]$' "$aws_config")" -eq 1

          for profile in \
            management management-readonly \
            deployment deployment-readonly \
            uat uat-readonly \
            production production-readonly
          do
            ${pkgs.gnugrep}/bin/grep -Fqx "[profile $profile]" "$aws_config"
          done

          if ${pkgs.gnugrep}/bin/grep -Eq '^\[(profile mor-|sso-session mor\])' "$aws_config"; then
            echo "Legacy mor AWS configuration remains." >&2
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
