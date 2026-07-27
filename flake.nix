{
  description = "With language compiler";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" ];

      flake.overlays.default = final: prev: {
        withlang-bin = prev.callPackage ./nix/withlang-bin { };
        withlang-ninja = prev.callPackage ./nix/withlang-ninja.nix {
          lld = prev.llvmPackages.lld;
          stdenv = prev.llvmPackages.stdenv;
        };
        withlang-cmake = prev.callPackage ./nix/withlang-cmake.nix {
          lld = prev.llvmPackages.lld;
          ninja = final.withlang-ninja;
          stdenv = prev.llvmPackages.stdenv;
        };
        withlang-llvm = prev.callPackage ./nix/withlang-llvm.nix {
          cmake = final.withlang-cmake;
          lld = prev.llvmPackages.lld;
          ninja = final.withlang-ninja;
          stdenv = prev.llvmPackages.stdenv;
        };
        withlang-seed = final.callPackage ./nix/withlang-seed { };
      };

      perSystem =
        { system, ... }:
        let
          pkgs = self.legacyPackages.${system};
        in
        {
          legacyPackages = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };

          packages = {
            default = pkgs.withlang-bin;
            inherit (pkgs)
              withlang-bin
              withlang-cmake
              withlang-llvm
              withlang-ninja
              withlang-seed
              ;
          };

          apps.default = {
            type = "app";
            program = "${pkgs.withlang-bin}/bin/with";
            meta.description = "Run the With compiler";
          };

          checks.withlang-bin = pkgs.withlang-bin;
        };
    };
}
