{
  description = "Starkify";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    miden-vm.url = "/Users/jakub.zalewski/Developer/miden-vm";
    miden-vm.flake = false;
  };

  outputs = inputs@{ self, flake-parts, rust-overlay, miden-vm, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        # To import a flake module
        # 1. Add foo to inputs
        # 2. Add foo as a parameter to the outputs function
        # 3. Add here: foo.flakeModule

      ];

      systems = [ "aarch64-darwin" ];

      perSystem = { config, self', inputs', pkgs, system, ... }: {
        # Per-system attributes can be defined here. The self' and inputs'
        # module parameters provide easy access to attributes of the same
        # system.
        _module.args.pkgs = import self.inputs.nixpkgs { inherit system; overlays = [ (import rust-overlay) ]; };

        # Equivalent to  inputs'.nixpkgs.legacyPackages.hello;
        packages =
          let
            rust = pkgs.rust-bin.stable."1.67.1".default;
            miden = pkgs.rustPlatform.buildRustPackage {
                pname = "miden-vm";
                version = "0.5.0";
                src = miden-vm;
                buildType = "release";
                buildFeatures = [ "executable" "concurrent" ];
                nativeBuildInputs = [ self'.packages.rust ];
                doCheck = false;
                cargoLock = {
                  lockFile = ./Cargo.lock;
                };
              };
            haskellPackages = pkgs.haskell.packages.ghc927.override {
              overrides = self: super: {
                wasm = pkgs.haskell.lib.dontCheck (self.callHackage "wasm" "1.1.1" {});
              };
            };
          in
          { inherit rust miden; };

        devShells.default = pkgs.mkShell {
          name = "starkify";

          buildInputs = with self'.packages; [
            rust miden
          ];

        };

      };

      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.


      };
    };
}