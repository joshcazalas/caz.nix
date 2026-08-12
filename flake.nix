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
  };

  outputs =
    inputs@{
      self,
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
    in
    {
      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          age
          deadnix
          nil
          nixfmt
          shellcheck
          sops
          statix
        ];
      };

      homeConfigurations."${settings.user.name}@cazpc" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = specialArgs;
        modules = [ ./hosts/cazpc/home.nix ];
      };

      nixosConfigurations.${settings.server.hostName} = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = [
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager
          ./hosts/homeserver
        ];
      };

      checks.${system} = {
        homeserver = self.nixosConfigurations.${settings.server.hostName}.config.system.build.toplevel;
        cazpc-home = self.homeConfigurations."${settings.user.name}@cazpc".activationPackage;
      };
    };
}
