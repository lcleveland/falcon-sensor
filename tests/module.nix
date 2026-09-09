{ pkgs, self }:

let
  # The real installer is proprietary and cannot live in CI, so the test builds
  # a synthetic .deb with the same layout: stub falcond/falconctl under
  # opt/CrowdStrike plus a vendor unit file. Everything else -- the package's
  # unpack/install phases, the bind mount, the credential plumbing -- is the
  # real code path.
  fakeDeb =
    pkgs.runCommand "falcon-sensor_0.0.0-test_amd64.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p pkg/DEBIAN pkg/opt/CrowdStrike pkg/lib/systemd/system

        {
          echo "Package: falcon-sensor"
          echo "Version: 0.0.0-test"
          echo "Architecture: amd64"
          echo "Maintainer: nobody <nobody@example.invalid>"
          echo "Description: synthetic Falcon sensor for the NixOS module test"
        } > pkg/DEBIAN/control

        # falconctl stub: record every invocation so the test can assert on the
        # argv the module built, including the values it read from credentials.
        {
          echo "#!${pkgs.runtimeShell}"
          echo 'printf "%s\n" "$*" >> /opt/CrowdStrike/falconctl.log'
          echo 'exit 0'
        } > pkg/opt/CrowdStrike/falconctl

        # falcond stub: forks and writes a PID file, matching Type=forking.
        {
          echo "#!${pkgs.runtimeShell}"
          echo '${pkgs.coreutils}/bin/sleep infinity &'
          echo 'echo $! > /var/run/falcond.pid'
          echo 'exit 0'
        } > pkg/opt/CrowdStrike/falcond

        {
          echo "#!${pkgs.runtimeShell}"
          echo 'echo "Host OS is not supported by Falcon (synthetic stub)"'
        } > pkg/opt/CrowdStrike/falcon-kernel-check

        # A read-only subdirectory, as the real .deb ships Packages/ and ASPM/.
        mkdir -p pkg/opt/CrowdStrike/subdir

        # A file the sensor would rewrite in place -- proves the copy is writable.
        echo "synthetic" > pkg/opt/CrowdStrike/falconstore

        {
          echo "[Unit]"
          echo "Description=CrowdStrike Falcon Sensor"
          echo "[Service]"
          echo "Type=forking"
          echo "ExecStart=/opt/CrowdStrike/falcond"
          echo "PIDFile=/var/run/falcond.pid"
          echo "Delegate=yes"
        } > pkg/lib/systemd/system/falcon-sensor.service

        chmod 0755 pkg/opt/CrowdStrike/falconctl \
                   pkg/opt/CrowdStrike/falcond \
                   pkg/opt/CrowdStrike/falcon-kernel-check

        chmod 0555 pkg/opt/CrowdStrike/subdir

        dpkg-deb --build pkg
        mv pkg.deb "$out"
      '';

  fakePackage = pkgs.callPackage ../pkgs/falcon-sensor.nix { srcOverride = fakeDeb; };
in
pkgs.testers.runNixOSTest {
  name = "falcon-sensor-module";

  # Second node: use the falcon-sensor.service that ships inside the .deb, with
  # this module contributing only a drop-in for ordering. Also the coverage for
  # the two credential options the first node does not exercise -- cidFile and
  # maintenanceTokenFile -- so every *File option is run, not just evaluated.
  nodes.vendorunit = {
    imports = [ self.nixosModules.default ];

    services.falcon-sensor = {
      enable = true;
      package = fakePackage;
      cidFile = "/run/falcon-test-secrets/cid";
      maintenanceTokenFile = "/run/falcon-test-secrets/maintenance-token";
      useVendorUnit = true;
    };

    # Generated at runtime so the values exist nowhere in the Nix store, which
    # is what makes the leak assertions meaningful rather than circular.
    systemd.services.falcon-test-secret = {
      description = "Provision test CID and maintenance token";
      wantedBy = [ "multi-user.target" ];
      before = [ "falcon-sensor-configure.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0700 /run/falcon-test-secrets
        hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F'; }
        printf '%s-01' "$(hex 16)" > /run/falcon-test-secrets/cid
        hex 16 > /run/falcon-test-secrets/maintenance-token
        chmod 0400 /run/falcon-test-secrets/*
      '';
    };
  };
  nodes.machine = {
    imports = [ self.nixosModules.default ];

    services.falcon-sensor = {
      enable = true;
      package = fakePackage;
      cid = "0123456789ABCDEF0123456789ABCDEF-01";
      provisioningTokenFile = "/run/falcon-test-secrets/provisioning-token";
      tags = [
        "Environment/Test"
        "Team/Platform"
      ];
      backend = "bpf";
    };

    # Stand-in for sops-nix/agenix. The token is generated at runtime from
    # /dev/urandom precisely so that it exists nowhere in the Nix store -- which
    # is what makes the "secret never reaches the store" assertion meaningful
    # rather than circular.
    systemd.services.falcon-test-secret = {
      description = "Provision a test provisioning token";
      wantedBy = [ "multi-user.target" ];
      before = [ "falcon-sensor-configure.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -d -m 0700 /run/falcon-test-secrets
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' \
          > /run/falcon-test-secrets/provisioning-token
        chmod 0400 /run/falcon-test-secrets/provisioning-token
      '';
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("state is relocated and bind-mounted"):
        machine.wait_for_unit("falcon-sensor-setup.service")
        machine.succeed("mountpoint -q /opt/CrowdStrike")
        machine.succeed("test -f /var/lib/falcon-sensor/opt/falcond")
        # A write through the hard-coded path must land in the state directory,
        # which is the single thing an impermanent host persists.
        machine.succeed("echo written-through > /opt/CrowdStrike/probe")
        machine.succeed("grep -q written-through /var/lib/falcon-sensor/opt/probe")

    with subtest("shipped files are writable in place"):
        machine.succeed("echo rewritten > /opt/CrowdStrike/falconstore")

    with subtest("re-running setup does not stack mounts"):
        machine.succeed("systemctl restart falcon-sensor-setup.service")
        machine.succeed("mountpoint -q /opt/CrowdStrike")
        count = machine.succeed("findmnt -n --target /opt/CrowdStrike -o TARGET | grep -c '^/opt/CrowdStrike$'")
        assert count.strip() == "1", f"expected exactly one mount, got {count.strip()}"
        # State survives the refresh.
        machine.succeed("grep -q written-through /opt/CrowdStrike/probe")


    with subtest("a package refresh keeps state but restores shipped files"):
        # falconstore carries the AID. Force a refresh by invalidating the
        # generation stamp, then check that the preserved file kept the value
        # the sensor wrote while a non-preserved shipped file was restored.
        machine.succeed("echo AID-I-MUST-KEEP > /opt/CrowdStrike/falconstore")
        machine.succeed("echo tampered > /opt/CrowdStrike/falcon-kernel-check")
        machine.succeed("echo stale > /var/lib/falcon-sensor/opt/.nix-generation")
        machine.succeed("systemctl restart falcon-sensor-setup.service")
        machine.succeed("grep -q AID-I-MUST-KEEP /opt/CrowdStrike/falconstore")
        machine.fail("grep -q tampered /opt/CrowdStrike/falcon-kernel-check")

    with subtest("a version bump removes the previous version's files"):
        # The real sensor ships version-stamped names (falconctl19402,
        # KernelModuleArchive19402, ...) behind unversioned symlinks, so an
        # upgrade must clear the old generation or >150MB is stranded in the
        # directory an impermanent host persists.
        machine.succeed("echo old > /var/lib/falcon-sensor/opt/falconctl19401")
        machine.succeed("echo falconctl19401 >> /var/lib/falcon-sensor/opt/.nix-manifest")
        machine.succeed("echo stale > /var/lib/falcon-sensor/opt/.nix-generation")
        machine.succeed("systemctl restart falcon-sensor-setup.service")
        machine.fail("test -e /opt/CrowdStrike/falconctl19401")
        # Runtime state the sensor itself created is not in the manifest and so
        # is never a removal candidate.
        machine.succeed("grep -q written-through /opt/CrowdStrike/probe")
        machine.succeed("grep -q AID-I-MUST-KEEP /opt/CrowdStrike/falconstore")

    with subtest("shipped subdirectories are writable"):
        # The .deb ships Packages/, ASPM/results, ASPM/tmp read-only; the
        # sensor writes into them at runtime.
        machine.succeed("touch /opt/CrowdStrike/subdir/written")
    with subtest("falconctl is configured with the expected arguments"):
        machine.wait_for_unit("falcon-sensor-configure.service")
        ctl_log = machine.succeed("cat /opt/CrowdStrike/falconctl.log")
        assert "--cid=0123456789ABCDEF0123456789ABCDEF-01" in ctl_log, ctl_log
        assert "--tags=Environment/Test,Team/Platform" in ctl_log, ctl_log
        assert "--backend=bpf" in ctl_log, ctl_log
        assert "--apd=true" in ctl_log, ctl_log

    with subtest("the provisioning token reaches falconctl"):
        token = machine.succeed("cat /run/falcon-test-secrets/provisioning-token").strip()
        assert len(token) == 32, f"unexpected token length {len(token)}"
        ctl_log = machine.succeed("cat /opt/CrowdStrike/falconctl.log")
        assert f"--provisioning-token={token}" in ctl_log, "token was not delivered to falconctl"

    with subtest("the provisioning token does not leak"):
        token = machine.succeed("cat /run/falcon-test-secrets/provisioning-token").strip()
        # Not in any generated unit ...
        machine.fail(f"grep -r --binary-files=text -q {token} /etc/systemd/system/")
        # ... not in the unit's own store closure ...
        machine.fail(
            "grep -r --binary-files=text -q "
            + token
            + " $(realpath /etc/systemd/system/falcon-sensor-configure.service)"
        )
        # ... and not in the journal.
        machine.fail(f"journalctl -u falcon-sensor-configure.service | grep -q {token}")

    with subtest("the sensor daemon runs"):
        machine.wait_for_unit("falcon-sensor.service")
        machine.succeed("systemctl is-active falcon-sensor.service")

    with subtest("the vendor's own unit is used when asked"):
        vendorunit.wait_for_unit("multi-user.target")
        vendorunit.succeed("mountpoint -q /opt/CrowdStrike")
        vendorunit.wait_for_unit("falcon-sensor.service")
        # The unit body came from the .deb, not from this module: the module
        # emits only a drop-in, so no full unit of its own is generated.
        vendorunit.succeed(
            "systemctl cat falcon-sensor.service | grep -q 'ExecStart=/opt/CrowdStrike/falcond'"
        )
        vendorunit.succeed(
            "test -d /etc/systemd/system/falcon-sensor.service.d"
        )

    with subtest("cidFile and maintenanceTokenFile are delivered from files"):
        vendorunit.wait_for_unit("falcon-sensor-configure.service")
        cid = vendorunit.succeed("cat /run/falcon-test-secrets/cid").strip()
        maint = vendorunit.succeed("cat /run/falcon-test-secrets/maintenance-token").strip()
        ctl_log = vendorunit.succeed("cat /opt/CrowdStrike/falconctl.log")

        assert f"--cid={cid}" in ctl_log, ctl_log
        assert f"--maintenance-token={maint}" in ctl_log, ctl_log

        # Tamper protection rejects every other change until the maintenance
        # token is set, so it must be the first falconctl call.
        lines = [x for x in ctl_log.splitlines() if x.strip()]
        assert "--maintenance-token=" in lines[0], f"maintenance token not applied first: {lines}"

    with subtest("neither the CID nor the maintenance token leaks"):
        cid = vendorunit.succeed("cat /run/falcon-test-secrets/cid").strip()
        maint = vendorunit.succeed("cat /run/falcon-test-secrets/maintenance-token").strip()
        for secret in (cid, maint):
            vendorunit.fail(f"grep -r --binary-files=text -q {secret} /etc/systemd/system/")
            vendorunit.fail(f"journalctl -u falcon-sensor-configure.service | grep -q {secret}")
  '';
}
