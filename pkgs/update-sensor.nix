{
  lib,
  writeShellApplication,
  curl,
  jq,
  coreutils,
  gnused,
  gnugrep,
  nix,
  dpkg,
  patchelf,
  stdenv,
  # Same set the packaged sensor links against; used to patch the ELF headers of
  # a sensor fetched at runtime, which never passes through autoPatchelfHook.
  openssl,
  libnl,
  zlib,
  elfutils,
  libbpf,
}:

writeShellApplication {
  name = "update-sensor";

  runtimeInputs = [
    curl
    jq
    coreutils
    gnused
    gnugrep
    nix
    dpkg
    patchelf
  ];

  # --install-dir needs to make a vendor binary runnable on a host with no
  # /lib64/ld-linux and no FHS library paths, so it rewrites the interpreter and
  # RPATH itself. Baked in here rather than discovered at runtime so the closure
  # is a build-time dependency and cannot drift from the packaged sensor.
  runtimeEnv = {
    FALCON_INTERPRETER = "${stdenv.cc.bintools.dynamicLinker}";
    FALCON_RPATH = lib.makeLibraryPath [
      stdenv.cc.cc.lib
      openssl
      libnl
      zlib
      elfutils
      libbpf
    ];
  };

  text = builtins.readFile ../tools/update-sensor.sh;

  meta = {
    description = "Pin or install a CrowdStrike Falcon sensor from the Sensor Download API";
    mainProgram = "update-sensor";
  };
}
