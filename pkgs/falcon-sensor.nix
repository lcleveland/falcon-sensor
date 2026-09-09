{
  lib,
  stdenv,
  requireFile,
  dpkg,
  autoPatchelfHook,
  patchelf,
  # Runtime libraries the sensor links against. Confirmed sufficient for 8.10 --
  # verify against a new .deb with `readelf -d` (see README "Packaging notes")
  # and extend rather than reaching for autoPatchelfIgnoreMissingDeps, which
  # would turn a missing library into a runtime crash instead of a build failure.
  openssl,
  libnl,
  zlib,
  elfutils,
  libbpf,

  # Which pin from ./sources.json to build. Defaults to the newest one there.
  # The sensor version a tenant may install is set by its own sensor update
  # policy, so this is expected to be overridden:
  #
  #   pkgs.falcon-sensor.override { version = "8.09.0-19204"; }
  #
  # `nix run .#update-sensor` adds pins to sources.json.
  version ? null,

  # For a version that is not in sources.json. Both must be given together;
  # they take precedence over the table.
  name ? null,
  hash ? null,

  sourcesFile ? ./sources.json,

  # Explicit source override (path/derivation); wins over everything. Used by
  # the VM test to substitute a synthetic .deb.
  #
  # Deliberately NOT named `src`: callPackage auto-fills any argument whose name
  # exists in the package set -- including ones that have a default here -- and
  # nixpkgs carries a *throwing* `pkgs.src` rename alias, so an argument named
  # `src` gets resolved to that alias and aborts evaluation as soon as the
  # source is forced. `srcOverride` collides with nothing, so the default holds.
  srcOverride ? null,
}:

let
  sources = if builtins.pathExists sourcesFile then lib.importJSON sourcesFile else { };

  # Debian version ordering: 8.10.0-19402 sorts above 8.9.0-19204 numerically,
  # not lexically, so compare component-wise.
  versionKeys = lib.sort (a: b: builtins.compareVersions a b < 0) (builtins.attrNames sources);
  newest = if versionKeys == [ ] then null else lib.last versionKeys;

  selected = if version != null then version else newest;

  pin =
    if name != null && hash != null then
      { inherit name hash; }
    else if selected != null && sources ? ${selected} then
      sources.${selected}
    else
      null;

  # The sensor is proprietary and sits behind an authenticated API, so it can
  # never be fetched during a build. The updater downloads it once, verifies the
  # hash the API declared, and does `nix-store --add-fixed sha256` -- which is
  # exactly what requireFile resolves. From then on the build is pure and
  # offline, and any other machine either has the blob already or runs the
  # updater once.
  pinnedSrc = requireFile {
    inherit (pin) name hash;
    url = "https://falcon.crowdstrike.com/host-management/sensor-downloads";
    message = ''
      The Falcon sensor installer ${pin.name} is pinned but is not in the Nix store.

      Fetch it from the CrowdStrike API and add it:

        nix run .#update-sensor -- \
          --client-id-file     /run/secrets/falcon-api-client-id \
          --client-secret-file /run/secrets/falcon-api-client-secret

      Or, if you downloaded it from the Falcon console by hand
      (Host setup and management -> Sensor downloads):

        nix-store --add-fixed sha256 ${pin.name}

      Expected hash: ${pin.hash}
    '';
  };

  unpinnedSrc = requireFile {
    name = "falcon-sensor.deb";
    hash = lib.fakeHash;
    message =
      if version != null then
        ''
          No pin for falcon-sensor version ${version} in ${toString sourcesFile}.

          Available: ${if versionKeys == [ ] then "(none)" else lib.concatStringsSep ", " versionKeys}

          Add one with `nix run .#update-sensor -- --sensor-version ${version}`,
          or pass `name` and `hash` directly:

            pkgs.falcon-sensor.override {
              name = "falcon-sensor_${version}_amd64.deb";
              hash = "sha256-...";
            }
        ''
      else
        ''
          No sensor is pinned yet -- ${toString sourcesFile} has no entries.

          Pin one from the CrowdStrike Sensor Download API (needs an API client
          with the "Sensor Download: read" scope):

            nix run .#update-sensor -- \
              --client-id-file     /run/secrets/falcon-api-client-id \
              --client-secret-file /run/secrets/falcon-api-client-secret

          That records the pin in sources.json (commit it -- it holds nothing
          secret and nothing specific to your tenant) and adds the installer to
          the store. See README "Pinning a sensor".
        '';
  };

  resolvedSrc =
    if srcOverride != null then
      srcOverride
    else if pin != null then
      pinnedSrc
    else
      unpinnedSrc;
in
stdenv.mkDerivation {
  pname = "falcon-sensor";
  version =
    if pin != null && pin ? version then
      pin.version
    else if selected != null then
      selected
    else
      "0-unpinned";

  src = resolvedSrc;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    patchelf
  ];

  buildInputs = [
    stdenv.cc.cc.lib # libstdc++.so.6, libgcc_s.so.1
    openssl
    libnl
    zlib
    elfutils # libelf, for the BPF backend
    libbpf
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" .
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  # The sensor is a signed, self-checking EDR binary; stripping it invites
  # integrity failures that surface only at runtime.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    if [ ! -d opt/CrowdStrike ]; then
      echo "falcon-sensor: the .deb did not contain opt/CrowdStrike -- layout changed?" >&2
      find . -maxdepth 3 -type d >&2
      exit 1
    fi

    mkdir -p "$out"
    cp -a opt "$out/opt"

    # Keep the vendor's own unit around: services.falcon-sensor.useVendorUnit
    # uses it directly, and the bind mount means its hard-coded paths already
    # resolve on a running system.
    for d in lib/systemd/system usr/lib/systemd/system; do
      if [ -d "$d" ]; then
        mkdir -p "$out/lib/systemd/system"
        cp -a "$d"/. "$out/lib/systemd/system/"
      fi
    done

    # Convenience entry points. The daemon itself is always started from the
    # bind-mounted /opt/CrowdStrike (see the module), never from the store.
    mkdir -p "$out/bin"
    for bin in falconctl falcond falcon-kernel-check falcon-diagnostic; do
      if [ -x "$out/opt/CrowdStrike/$bin" ]; then
        ln -s "$out/opt/CrowdStrike/$bin" "$out/bin/$bin"
      fi
    done

    runHook postInstall
  '';

  passthru = {
    # The sensor hard-codes this path; the module materialises it as a bind
    # mount over its state directory.
    installDir = "/opt/CrowdStrike";
    inherit sources;
    # Deliberately no updateScript: refreshing this pin needs CrowdStrike API
    # credentials and returns whatever version the tenant's sensor update policy
    # allows, so it cannot run unattended. Use tools/update-sensor.sh.
  };

  meta = {
    description = "CrowdStrike Falcon sensor for Linux (proprietary EDR agent)";
    homepage = "https://www.crowdstrike.com/";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "falconctl";
  };
}
