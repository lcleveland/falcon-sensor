{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  jq,
  systemd,
}:

writeShellApplication {
  name = "falcon-sensor-status";

  runtimeInputs = [
    coreutils
    gnugrep
    gnused
    jq
    systemd # systemctl, for the unit's own state
  ];

  text = builtins.readFile ../tools/falcon-sensor-status.sh;

  meta = {
    description = "Publish the CrowdStrike Falcon sensor's state as JSON";
    mainProgram = "falcon-sensor-status";
  };
}
