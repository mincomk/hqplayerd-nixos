{
  description = "HQPlayer Embedded 6.x (hqplayerd) packaged for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" ];
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (mkPkgs system));
    in
    {
      packages = forAllSystems (pkgs: rec {
        hqplayerd = pkgs.callPackage ./hqplayerd.nix { };
        default = hqplayerd;
      });

      # Replaces nixpkgs' broken hqplayerd everywhere, including
      # services.hqplayerd, which hard-codes pkgs.hqplayerd.
      overlays.default = final: prev: {
        hqplayerd = final.callPackage ./hqplayerd.nix { };
      };

      nixosModules.default = {
        nixpkgs.overlays = [ self.overlays.default ];
      };
      nixosModules.hqplayerd = self.nixosModules.default;
    };
}
