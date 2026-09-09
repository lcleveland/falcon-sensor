{
  description = "CrowdStrike Falcon sensor for Linux, packaged as a NixOS module (x86_64)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs { inherit system; };

      falcon-sensor-fetch = pkgs.callPackage ./pkgs/falcon-sensor-fetch.nix { };
    in
    {
      packages.${system} = {
        inherit falcon-sensor-fetch;
        default = falcon-sensor-fetch;
      };

      # `nix run .#find-sensor -- --client-id-file … --client-secret-file …`
      # lists the sensors your tenant can install, each with the SRI hash to
      # paste into services.falcon-sensor.hash.
      apps.${system} = {
        find-sensor = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "find-sensor" ''
              exec ${lib.getExe falcon-sensor-fetch} --list "$@"
            ''
          );
          meta.description = "List the Falcon sensors this tenant can install, with their hashes";
        };
        default = self.apps.${system}.find-sensor;
      };

      nixosModules.default = import ./modules/falcon-sensor.nix;

      # Makes `pkgs.falcon-sensor-fetch` resolve, which is what the module's
      # fetcher default looks for. Optional -- the module falls back to
      # callPackage when the overlay is absent.
      overlays.default = final: _prev: {
        falcon-sensor-fetch = final.callPackage ./pkgs/falcon-sensor-fetch.nix { };
      };

      # VM test against a synthetic sensor -- the real installer is proprietary
      # and the API is unreachable from a test VM. See tests/module.nix.
      checks.${system}.module = import ./tests/module.nix { inherit pkgs self; };

      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          dpkg
          patchelf
          file
          binutils # readelf, for inspecting the sensor binaries
          curl
          jq
          shellcheck
        ];
      };
    };
}
