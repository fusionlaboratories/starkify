{
  description = "Starkify";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    inclusive.url = "github:input-output-hk/nix-inclusive";
    miden-vm.url = "github:qredek/miden-vm/add-exitcodes";
    miden-vm.flake = false;
    cairo-lang.url = "github:starkware-libs/cairo-lang/v0.10.3";
    cairo-lang.flake = false;
    devenv.url = "github:cachix/devenv";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    rust-overlay,
    miden-vm,
    inclusive,
    cairo-lang,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        # To import a flake module
        # 1. Add foo to inputs
        # 2. Add foo as a parameter to the outputs function
        # 3. Add here: foo.flakeModule
        inputs.devenv.flakeModule
        ./nix/docker-module.nix
      ];

      systems = ["aarch64-linux" "aarch64-darwin"];

      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
        # Per-system attributes can be defined here. The self' and inputs'
        # module parameters provide easy access to attributes of the same
        # system.
        _module.args.pkgs = import self.inputs.nixpkgs {
          inherit system;
          overlays = [(import rust-overlay)];
        };

        # Equivalent to  inputs'.nixpkgs.legacyPackages.hello;
        packages.rust = pkgs.rust-bin.stable."1.67.1".default;
        packages.miden = pkgs.rustPlatform.buildRustPackage {
          pname = "miden-vm";
          version = "0.5.0";
          src = miden-vm;
          buildType = "release";
          buildFeatures = ["executable" "concurrent"];
          nativeBuildInputs = [self'.packages.rust];
          doCheck = false;
          cargoLock = {
            lockFile = "${miden-vm}/Cargo.lock";
          };
        };

        legacyPackages.haskellPackages = pkgs.haskell.packages.ghc927.override {
          overrides = self: super: {
            wasm = pkgs.haskell.lib.dontCheck (self.callHackage "wasm" "1.1.1" {});
          };
        };

        legacyPackages.starkify-src = inclusive.lib.inclusive ./. [
          ./src
          ./app
          ./tests
          ./starkify.cabal
        ];

        packages.starkify = with self'.legacyPackages; (haskellPackages.callCabal2nix "starkify" starkify-src {}).overrideAttrs (old: {doCheck = false;});

        packages.ghc = with self'.legacyPackages;
          haskellPackages.ghcWithPackages (
            p: (
              with self'.packages;
                starkify.getCabalDeps.executableHaskellDepends
                ++ starkify.getCabalDeps.libraryHaskellDepends
                ++ starkify.getCabalDeps.testHaskellDepends
            )
          );

        packages.python = pkgs.python39;

        packages.web3-fixed = with self'.packages;
          python.pkgs.web3.override {
            # TODO: Check how IPFS is used, and whether it works on macOS
            ipfshttpclient = python.pkgs.ipfshttpclient.overridePythonAttrs {
              meta.broken = false;
            };
          };

        packages.cairo-lang = with self'.packages;
          python.pkgs.buildPythonPackage {
            pname = "cairo-lang";
            version = "0.10.3";
            nativeBuildInputs = [python.pkgs.pythonRelaxDepsHook];
            pythonRelaxDeps = ["frozendict"];
            pythonRemoveDeps = ["pytest" "pytest-asyncio"];
            doCheck = false;
            buildInputs = [pkgs.gmp];
            propagatedBuildInputs = with python.pkgs; ([
                aiohttp
                cachetools
                setuptools
                ecdsa
                fastecdsa
                sympy
                mpmath
                numpy
                typeguard
                frozendict
                prometheus-client
                marshmallow
                marshmallow-enum
                marshmallow-dataclass
                marshmallow-oneofschema
                pipdeptree
                lark
                eth-hash
                pyyaml
                web3-fixed
              ]
              ++ eth-hash.optional-dependencies.pycryptodome);
            postInstall = ''
              chmod +x $out/bin/*
            '';
          };

        devenv.shells.default = {
          packages = with pkgs;
            [
              llvmPackages_14.clang
              llvmPackages_14.libllvm
              lld_14
              cabal-install
              wabt
              wasmtime
            ]
            ++ (with self'.packages; [
              miden
              rust
              ghc
              cairo-lang
            ]);
        };

        # nix fmt flake.nix
        formatter = pkgs.alejandra;
      };

      flake = {
        # The usual flake attributes can be defined here, including system-
        # agnostic ones like nixosModule and system-enumerating ones, although
        # those are more easily expressed in perSystem.
      };
    };
}
