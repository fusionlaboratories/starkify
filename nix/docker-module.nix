# Flake module for generating a docker image
# Can be loaded into docker using
#
# $ docker load <(nix build .#docker --print-out-paths)
{
  self,
  lib,
  ...
}: {
  systems = ["aarch64-linux" "aarch64-darwin"];

  perSystem = {
    config,
    self',
    inputs',
    pkgs,
    ...
  }: {
    packages.docker = pkgs.dockerTools.buildImage {
      name = "starkify";
      tag = "latest";
      created = "now";
      fromImage = pkgs.dockerTools.buildImage {
        name = "starkify-base";
        fromImageName = "scratch";
        copyToRoot = [
          pkgs.dockerTools.usrBinEnv
          pkgs.dockerTools.binSh
          pkgs.dockerTools.caCertificates
          pkgs.dockerTools.fakeNss
          # Ensure that /tmp exists, since this is used for clang-14 output
          (pkgs.symlinkJoin {
            name = "tmpdir";
            paths = [(pkgs.runCommand "" {} "mkdir -p $out/tmp")];
          })
          # LLVM packages adds ~1.3GB to the docker image
          pkgs.llvmPackages_14.clang.cc
          pkgs.llvmPackages_14.libllvm
          pkgs.lld_14
        ];
      };
      copyToRoot =
        [
          (pkgs.runCommand "starkify-env" {} ''
            mkdir -p $out/bin
            cp ${self'.packages.starkify}/bin/starkify $out/bin/starkify
            cp ${self'.packages.miden}/bin/miden $out/bin/miden
          '')
        ]
        # Not needed for image to function, but useful for debugging from a shell
        ++ (with pkgs; [coreutils which gnugrep vim]);
    };
  };
}
