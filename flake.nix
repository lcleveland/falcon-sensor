{
  description = "CrowdStrike Falcon sensor for Linux, packaged as a NixOS module (x86_64)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # the Falcon sensor is proprietary
      };

      # Pins a sensor into pkgs/sources.json, or installs one straight into a
      # host's state directory with --install-dir. See README "Pinning a sensor"
      # and "Fetching on the host".
      update-sensor = pkgs.callPackage ./pkgs/update-sensor.nix { };
    in
    {
      packages.${system} = {
        falcon-sensor = pkgs.callPackage ./pkgs/falcon-sensor.nix { };
        inherit update-sensor;
        default = self.packages.${system}.falcon-sensor;
      };

      apps.${system}.update-sensor = {
        type = "app";
        program = "${update-sensor}/bin/update-sensor";
        meta.description = "Pin a Falcon sensor installer from the CrowdStrike Sensor Download API";
      };

      nixosModules.default = import ./modules/falcon-sensor.nix;

      # Makes `pkgs.falcon-sensor` resolve, which is what the module's `package`
      # default and a future nixpkgs `mkPackageOption` both look for. Not
      # required -- the module falls back to callPackage when the overlay is
      # absent -- but applying it lets you `.override { version = ...; }` the
      # same way you would upstream.
      overlays.default = final: _prev: {
        falcon-sensor = final.callPackage ./pkgs/falcon-sensor.nix { };
        falcon-update-sensor = final.callPackage ./pkgs/update-sensor.nix { };
      };

      # VM test against a synthetic .deb -- the real installer is proprietary
      # and cannot live in CI. See tests/module.nix.
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
