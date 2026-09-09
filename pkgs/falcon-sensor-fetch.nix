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
  name = "falcon-sensor-fetch";

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

  # Installing needs to make a vendor binary runnable on a host with no
  # /lib64/ld-linux and no FHS library paths, so it rewrites the interpreter and
  # RPATH itself. Baked in here rather than discovered at runtime so the closure
  # is a build-time dependency of this tool rather than something resolved on
  # the host at install time.
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

  text = builtins.readFile ../tools/falcon-sensor-fetch.sh;

  meta = {
    description = "Download and install a CrowdStrike Falcon sensor from the Sensor Download API";
    mainProgram = "falcon-sensor-fetch";
  };
}
