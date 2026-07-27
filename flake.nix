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
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];

      flake.overlays.default =
        final: prev:
        {
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
        }
        // nixpkgs.lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
          withlang-bin = prev.callPackage ./nix/withlang-bin { };
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
            inherit (pkgs)
              withlang-cmake
              withlang-llvm
              withlang-ninja
              withlang-seed
              ;
          }
          // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
            default = pkgs.withlang-bin;
            inherit (pkgs) withlang-bin;
          };

          apps = nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
            default = {
              type = "app";
              program = "${pkgs.withlang-bin}/bin/with";
              meta.description = "Run the With compiler";
            };
          };

          checks = nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
            withlang-bin = pkgs.withlang-bin;
          };
        };
    };
}
