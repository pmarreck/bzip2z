{
	description = "bzip2z dev shell + flake-native CI checks";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		progrez = {
			url = "github:pmarreck/progrez/yolo";
			flake = false;
		};
	};

	outputs = { self, nixpkgs, progrez }:
		let
			devSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
			ciHostSystems = [ "x86_64-linux" ];
			forSystems = systems: f: nixpkgs.lib.genAttrs systems (system: f system (import nixpkgs { inherit system; }));

			mkCiPackage = pkgs: name: zigTarget: runTests:
				pkgs.stdenv.mkDerivation {
					pname = "bzip2z-${name}";
					version = "0.1.0";
					src = self;
					strictDeps = true;
					dontConfigure = true;
					nativeBuildInputs = [
						pkgs.bash
						pkgs.coreutils
						pkgs.zig
						pkgs.bzip2
						pkgs.pbzip2
					];

					buildPhase = let
						zigPkgHash = "progrez-0.1.0-0YJXrt4AAgAa3oScbj1pXFwos1rhFzR50M6sQSJBmZHg";
					in ''
						runHook preBuild
						export HOME="$TMPDIR/home"
						mkdir -p "$HOME"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
						mkdir -p "$TMPDIR/zig-system-pkg/${zigPkgHash}"
						cp -r ${progrez}/* "$TMPDIR/zig-system-pkg/${zigPkgHash}/"
						${if runTests then ''
						zig build test --system "$TMPDIR/zig-system-pkg"
						patchShebangs build tests/cli_test
						# Override build script to pass --system so cli_test doesn't hit network
						cat > build <<BUILDEOF
#!/usr/bin/env bash
exec zig build --system "$TMPDIR/zig-system-pkg" "\$@"
BUILDEOF
						chmod +x build
						patchShebangs build
						bash tests/cli_test
						'' else ":"}
						zig build -Doptimize=ReleaseFast -Dtarget=${zigTarget} --system "$TMPDIR/zig-system-pkg"
						runHook postBuild
					'';

					installPhase = ''
						runHook preInstall
						mkdir -p "$out"
						cp -R zig-out/bin "$out/bin"
						if [ -d zig-out/lib ]; then
							cp -R zig-out/lib "$out/lib"
						fi
						runHook postInstall
					'';
				};
		in {
			devShells = forSystems devSystems (system: pkgs: {
				default = pkgs.mkShell {
					packages = [
						pkgs.zig
						pkgs.zls
						pkgs.git
						pkgs.ripgrep
						pkgs.bzip2
						pkgs.pbzip2
					];

					shellHook = ''
						export ZIG_GLOBAL_CACHE_DIR="''${TMPDIR:-/tmp}/zig-global-cache"
						echo "bzip2z dev shell: zig/zls/bzip2"
					'';
				};
			});

			packages = forSystems ciHostSystems (system: pkgs:
				let
					mk = name: target: runTests: mkCiPackage pkgs name target runTests;
				in {
					default = mk "linux-x86_64" "x86_64-linux-gnu" false;
					ci-tests = mk "linux-x86_64-tests" "x86_64-linux-gnu" true;
					ci-linux-x86_64 = mk "linux-x86_64" "x86_64-linux-gnu" false;
					ci-linux-aarch64 = mk "linux-aarch64" "aarch64-linux-gnu" false;
					ci-macos-aarch64 = mk "macos-aarch64" "aarch64-macos" false;
					ci-windows-x86_64 = mk "windows-x86_64" "x86_64-windows-gnu" false;
					ci-windows-aarch64 = mk "windows-aarch64" "aarch64-windows-gnu" false;
				});

			checks = forSystems ciHostSystems (system: pkgs:
				let p = self.packages.${system};
				in {
					unit-and-cli-tests = p.ci-tests;
					target-linux-x86_64 = p.ci-linux-x86_64;
					target-linux-aarch64 = p.ci-linux-aarch64;
					target-macos-aarch64 = p.ci-macos-aarch64;
					target-windows-x86_64 = p.ci-windows-x86_64;
					target-windows-aarch64 = p.ci-windows-aarch64;
				});
		};
}
