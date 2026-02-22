{
	description = "bzip2z dev shell + flake-native CI checks";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
			forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system (import nixpkgs { inherit system; }));

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

					buildPhase = ''
						runHook preBuild
						export HOME="$TMPDIR/home"
						mkdir -p "$HOME"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
						${if runTests then "./test" else ":"}
						./build -Doptimize=ReleaseFast -Dtarget=${zigTarget}
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
			devShells = forAllSystems (system: pkgs: {
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

			packages = forAllSystems (system: pkgs:
				let
					mk = name: target: runTests: mkCiPackage pkgs name target runTests;
					defaultPackage = if system == "aarch64-darwin"
						then mk "macos-aarch64" "aarch64-macos" false
						else mk "linux-x86_64" "x86_64-linux-gnu" false;
				in {
					default = defaultPackage;
				} // (if system == "x86_64-linux" then {
					ci-tests = mk "linux-x86_64-tests" "x86_64-linux-gnu" true;
					ci-linux-x86_64 = mk "linux-x86_64" "x86_64-linux-gnu" false;
					ci-linux-aarch64 = mk "linux-aarch64" "aarch64-linux-gnu" false;
					ci-windows-x86_64 = mk "windows-x86_64" "x86_64-windows-gnu" false;
					ci-windows-aarch64 = mk "windows-aarch64" "aarch64-windows-gnu" false;
				} else if system == "aarch64-darwin" then {
					ci-tests = mk "macos-aarch64-tests" "aarch64-macos" true;
					ci-macos-aarch64 = mk "macos-aarch64" "aarch64-macos" false;
				} else if system == "aarch64-linux" then {
					ci-linux-aarch64 = mk "linux-aarch64" "aarch64-linux-gnu" false;
				} else {
				}));

			checks = forAllSystems (system: pkgs:
				let p = self.packages.${system};
				in if system == "x86_64-linux" then {
					unit-and-cli-tests = p.ci-tests;
					target-linux-x86_64 = p.ci-linux-x86_64;
					target-linux-aarch64 = p.ci-linux-aarch64;
					target-windows-x86_64 = p.ci-windows-x86_64;
					target-windows-aarch64 = p.ci-windows-aarch64;
				} else if system == "aarch64-darwin" then {
					unit-and-cli-tests = p.ci-tests;
					target-macos-aarch64 = p.ci-macos-aarch64;
				} else if system == "aarch64-linux" then {
					target-linux-aarch64 = p.ci-linux-aarch64;
				} else {
				});
		};
}
