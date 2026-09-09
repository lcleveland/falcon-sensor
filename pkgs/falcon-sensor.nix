{
  lib,
  stdenv,
  requireFile,
  dpkg,
  autoPatchelfHook,
  patchelf,
  # Runtime libraries the sensor links against. This set is a starting point --
  # verify it against a real .deb with `readelf -d` (see README "Packaging
  # notes") and extend it rather than reaching for autoPatchelfIgnoreMissingDeps,
  # which would turn a missing library into a runtime crash instead of a build
  # failure.
  openssl,
  libnl,
  zlib,
  elfutils,
  libbpf,

  # Pin produced by `nix run .#update-sensor` (tools/update-sensor.sh).
  lockFile ? ../sensor.lock.json,

  # Explicit source override (path/derivation); wins over the lockfile. Used by
  # the VM test to substitute a synthetic .deb.
  #
  # Deliberately NOT named `src`: callPackage auto-fills any argument whose name
  # exists in the package set -- including ones that have a default here -- and
  # nixpkgs carries a *throwing* `pkgs.src` rename alias, so an argument named
  # `src` gets resolved to that alias and aborts evaluation as soon as the
  # source is forced. `srcOverride` collides with nothing, so the default holds.
  # (Same lesson as netskope-client/pkgs/netskope-client.nix.)
  srcOverride ? null,
}:

let
  hasLock = lockFile != null && builtins.pathExists lockFile;
  lock = if hasLock then builtins.fromJSON (builtins.readFile lockFile) else null;

  # The sensor is proprietary and sits behind an authenticated API, so it can
  # never be fetched during a build. The updater downloads it once, verifies the
  # sha256 the API declared, and does `nix-store --add-fixed sha256` -- which is
  # exactly the flat hash requireFile resolves. From then on the build is pure
  # and offline, and any other machine either has the blob already or runs the
  # updater once.
  lockedSrc = requireFile {
    name = lock.name;
    sha256 = lock.sha256;
    message = ''
      The Falcon sensor installer ${lock.name} (version ${lock.version}) is
      pinned in ${toString lockFile} but is not in the Nix store.

      Fetch it from the CrowdStrike API and add it:

        nix run .#update-sensor -- \
          --client-id-file     /run/secrets/falcon-api-client-id \
          --client-secret-file /run/secrets/falcon-api-client-secret

      Or, if you downloaded it from the Falcon console by hand
      (Host setup and management -> Sensor downloads):

        nix-store --add-fixed sha256 ${lock.name}

      Expected sha256: ${lock.sha256}
    '';
  };

  unpinnedSrc = requireFile {
    name = "falcon-sensor.deb";
    hash = lib.fakeHash;
    message = ''
      No sensor is pinned yet -- ${toString lockFile} does not exist.

      Pin one from the CrowdStrike Sensor Download API (needs an API client with
      the "Sensor Download: read" scope):

        nix run .#update-sensor -- \
          --client-id-file     /run/secrets/falcon-api-client-id \
          --client-secret-file /run/secrets/falcon-api-client-secret

      That writes sensor.lock.json (commit it -- it holds no secrets) and adds
      the installer to the store. See README "Pinning a sensor".
    '';
  };

  resolvedSrc =
    if srcOverride != null then
      srcOverride
    else if hasLock then
      lockedSrc
    else
      unpinnedSrc;
in
stdenv.mkDerivation {
  pname = "falcon-sensor";
  version = if hasLock then lock.version else "0-unpinned";

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

    # Keep the vendor's own unit around: the module mirrors its settings rather
    # than inventing them, and the bind mount means its hard-coded paths are
    # already correct on a running system.
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
    inherit lock;
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
