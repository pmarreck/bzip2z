{
  description = "progrez - unified progress indication library for CLI tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        progrez = pkgs.stdenv.mkDerivation {
          pname = "progrez";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build --prefix $out -Doptimize=ReleaseFast
          '';

          dontInstall = true;
        };
      in {
        packages.default = progrez;

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "progrez-test";
          version = "0.1.0";
          src = self;

          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;

          buildPhase = ''
            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build test
          '';

          installPhase = ''
            touch $out
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.zig
            pkgs.hyperfine
          ];

          shellHook = ''
            echo "progrez dev shell"
            echo "  zig: $(zig version)"
          '';
        };
      }
    );
}
