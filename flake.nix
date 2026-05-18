{
	description = "bzip2z dev shell + flake-native CI checks";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		zig-overlay = {
			url = "github:mitchellh/zig-overlay";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = { self, nixpkgs, zig-overlay }:
		let
			pname = "bzip2z";
			version = "0.1.0";
			devSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
			ciHostSystems = [ "x86_64-linux" ];
			allBuildSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
			zigFor = system: zig-overlay.packages.${system}."0.16.0";
			forSystems = systems: f: nixpkgs.lib.genAttrs systems (system: f system (import nixpkgs { inherit system; }) (zigFor system));

			zigDepsHash = "sha256-KrwTu200E7aiyP2PUTQLx6umntZTBWBxt3Bohx0wyBM=";

			mkZigDeps = pkgs: zig: pkgs.stdenv.mkDerivation {
				pname = "${pname}-zig-deps";
				inherit version;
				src = self;
				nativeBuildInputs = with pkgs; [ zig git cacert ];
				outputHashMode = "recursive";
				outputHashAlgo = "sha256";
				outputHash = zigDepsHash;
				buildPhase = ''
					export HOME=$TMPDIR
					export ZIG_GLOBAL_CACHE_DIR=$out
					export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
					export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
					zig build --fetch=all
				'';
				dontInstall = true;
				dontFixup = true;
			};

			mkCiPackage = pkgs: zig: name: zigTarget: runTests:
				let
					isDarwin = pkgs.stdenv.isDarwin;
					zigDeps = mkZigDeps pkgs zig;
				in
				pkgs.stdenv.mkDerivation {
					pname = "${pname}-${name}";
					inherit version;
					src = self;
					strictDeps = true;
					dontConfigure = true;
					nativeBuildInputs = [
						pkgs.bash
						pkgs.coreutils
						zig
						pkgs.bzip2
						pkgs.pbzip2
					] ++ pkgs.lib.optionals isDarwin [
						pkgs.darwin.cctools
						pkgs.apple-sdk
					];

					buildPhase = ''
						runHook preBuild
						export HOME="$TMPDIR/home"
						mkdir -p "$HOME"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
						cp -r ${zigDeps}/* "$ZIG_GLOBAL_CACHE_DIR/"
						chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
						${if runTests then ''
						# On Linux, Zig with link_libc bakes /lib64/ld-linux-x86-64.so.2
						# as the dynamic linker, which doesn't exist in the Nix sandbox.
						# patchelf 0.18 aborts on Zig 0.16 ELFs and -Ddynamic-linker
						# breaks shared-lib subcompilation. Instead, compile artifacts
						# and run each via Nix's loader directly. The CLI gets a thin
						# shell wrapper so test_cli's $cli invocations work unchanged.
						${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
						zig build test-compile
						zig build
						DL_PATH="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
						rc=0
						for f in zig-out/test-bins/*; do
							[ -x "$f" ] || continue
							"$DL_PATH" "$f" || rc=1
						done
						[ $rc -eq 0 ] || { echo "Unit/bench tests failed"; exit 1; }
						patchShebangs build tests/cli_test
						# Wrap all binaries in zig-out/bin via Nix's loader.
						for orig in zig-out/bin/*; do
							[ -f "$orig" ] || continue
							[ -x "$orig" ] || continue
							case "$orig" in *.real) continue ;; esac
							mv "$orig" "$orig.real"
							cat > "$orig" <<WRAPPER
#!${pkgs.runtimeShell}
exec "$DL_PATH" "\$(dirname "\$0")/\$(basename "\$0").real" "\$@"
WRAPPER
							chmod +x "$orig"
						done
						ls -la zig-out/bin/
						bash tests/cli_test
						''}
						${pkgs.lib.optionalString (!pkgs.stdenv.isLinux) ''
						zig build test
						zig build
						patchShebangs build tests/cli_test
						bash tests/cli_test
						''}
						'' else ":"}
						zig build -Doptimize=ReleaseFast -Dtarget=${zigTarget}
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
			devShells = forSystems devSystems (system: pkgs: zig: {
				default = pkgs.mkShell {
					packages = [
						zig
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

			# Expose zigDeps for hash discovery on any build system
			legacyPackages = forSystems allBuildSystems (system: pkgs: zig: {
				zigDeps = mkZigDeps pkgs zig;
			});

			packages = forSystems allBuildSystems (system: pkgs: zig:
				let
					mk = name: target: runTests: mkCiPackage pkgs zig name target runTests;
					nativeTarget = {
						"x86_64-linux" = "x86_64-linux-gnu";
						"aarch64-linux" = "aarch64-linux-gnu";
						"aarch64-darwin" = "aarch64-macos";
					}.${system};
					nativeName = {
						"x86_64-linux" = "linux-x86_64";
						"aarch64-linux" = "linux-aarch64";
						"aarch64-darwin" = "macos-aarch64";
					}.${system};
				in {
					default = mk nativeName nativeTarget false;
				} // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
					ci-tests = mk "linux-x86_64-tests" "x86_64-linux-gnu" true;
					ci-linux-x86_64 = mk "linux-x86_64" "x86_64-linux-gnu" false;
					ci-linux-aarch64 = mk "linux-aarch64" "aarch64-linux-gnu" false;
					ci-macos-aarch64 = mk "macos-aarch64" "aarch64-macos" false;
					ci-windows-x86_64 = mk "windows-x86_64" "x86_64-windows-gnu" false;
					ci-windows-aarch64 = mk "windows-aarch64" "aarch64-windows-gnu" false;
				});

			checks = forSystems ciHostSystems (system: pkgs: zig:
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
