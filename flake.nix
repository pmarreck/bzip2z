{
	description = "bzip2z dev shell";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
			forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
		in {
			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
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
		};
}
