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

      # Pins a sensor from the CrowdStrike Sensor Download API and writes
      # sensor.lock.json. See README "Pinning a sensor".
      update-sensor = pkgs.writeShellApplication {
        name = "update-sensor";
        runtimeInputs = with pkgs; [
          curl
          jq
          coreutils
          gnused
          gnugrep
          nix
        ];
        text = builtins.readFile ./tools/update-sensor.sh;
      };
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
