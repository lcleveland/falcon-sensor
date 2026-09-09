{ pkgs, self }:

let
  lib = pkgs.lib;

  # The real installer is proprietary and the CrowdStrike API is unreachable
  # from a test VM, so the fetch tool is swapped for a stub with the same
  # interface. Everything the module owns is still the real code path:
  # credential delivery, ordering, the bind mount, preserveFiles, and the
  # no-network-when-already-installed check.
  #
  # The stub ships the layout the real 8.10 .deb does, including a read-only
  # subdirectory and version-stamped names behind unversioned symlinks.
  stubSensor =
    version:
    pkgs.runCommand "falcon-sensor-stub-${version}" { } ''
      mkdir -p "$out/opt/CrowdStrike/subdir"

      # Answers `-g` reads in the formats the real falconctl uses -- which are
      # not one format but several, including a sentence for anything unset --
      # and records every *write* so the test can assert on the argv the module
      # built, including values it read from credentials.
      #
      # Reads are deliberately not logged: falcon-sensor-status runs `-g` from a
      # timer, so logging those would interleave with the writes and break the
      # assertion that the maintenance token is applied first.
      cat > "$out/opt/CrowdStrike/falconctl${version}" <<EOF
      #!${pkgs.runtimeShell}
      if [ "\$1" = "-g" ]; then
        shift
        for flag in "\$@"; do
          case "\$flag" in
            --version)    echo "version = 8.10.0-${version}." ;;
            --rfm-state)  echo "rfm-state=true." ;;
            --rfm-reason) echo "rfm-reason=Unsupported kernel." ;;
            --backend)    echo "backend=bpf." ;;
            --aid)        echo 'aid="0123456789abcdef0123456789abcdef".' ;;
            --cid)        echo "cid is not set." ;;
          esac
        done
        exit 0
      fi
      printf "%s\n" "\$*" >> /opt/CrowdStrike/falconctl.log
      exit 0
      EOF

      # Forks and writes a PID file, matching Type=forking.
      cat > "$out/opt/CrowdStrike/falcond${version}" <<EOF
      #!${pkgs.runtimeShell}
      ${pkgs.coreutils}/bin/sleep infinity &
      echo \$! > /var/run/falcond.pid
      exit 0
      EOF

      chmod 0555 "$out/opt/CrowdStrike"/falcon*${version}
      ln -s "falconctl${version}" "$out/opt/CrowdStrike/falconctl"
      ln -s "falcond${version}" "$out/opt/CrowdStrike/falcond"
      echo "${version}" > "$out/opt/CrowdStrike/version-marker"
      chmod -R a-w "$out/opt/CrowdStrike/subdir"
    '';

  # Stands in for falcon-sensor-fetch. Honours --hash, --install-dir and
  # --preserve exactly as the real tool does, including the pre-network
  # idempotence check, so what is under test is the module's contract with it.
  stubFetch =
    sensors:
    pkgs.writeShellApplication {
      name = "falcon-sensor-fetch";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        install_dir=""; want=""; preserve=""; id=""; secret=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --install-dir) install_dir="$2"; shift 2 ;;
            --hash) want="$2"; shift 2 ;;
            --preserve) preserve="$2"; shift 2 ;;
            --client-id-file) id="$(cat "$2")"; shift 2 ;;
            --client-secret-file) secret="$(cat "$2")"; shift 2 ;;
            *) shift ;;
          esac
        done

        # Prove the credentials arrived, without putting them on any argv.
        printf '%s %s\n' "$id" "$secret" > /run/stub-fetch-saw

        # Without --hash the real tool must ask the API which sensor to use;
        # record that, so the test can assert when the network was needed.
        if [ -z "$want" ]; then
          echo resolved-via-api >> /run/stub-fetch-calls
          want="${builtins.head (builtins.attrNames sensors)}"
        fi

        if [ "$(cat "$install_dir/.installed-hash" 2>/dev/null || true)" = "$want" ]; then
          echo "already installed, nothing to do" >&2
          exit 0
        fi
        echo downloaded >> /run/stub-fetch-calls

        src=""
        ${lib.concatStringsSep "\n        " (
          lib.mapAttrsToList (h: p: ''if [ "$want" = "${h}" ]; then src="${p}/opt/CrowdStrike"; fi'') sensors
        )}
        [ -n "$src" ] || { echo "stub: no sensor for $want" >&2; exit 1; }

        staging="$(mktemp -d)"
        cp -a "$src/." "$staging/"
        chmod -R u+w "$staging"

        install -d -m 0755 "$install_dir"
        for keep in $preserve; do
          if [ -e "$install_dir/$keep" ]; then cp -a "$install_dir/$keep" "$staging/$keep"; fi
        done

        find "$install_dir" -mindepth 1 -maxdepth 1 ! -name '.installed-hash' -exec rm -rf {} +
        cp -a "$staging/." "$install_dir/"
        rm -rf "$staging"
        printf %s "$want" > "$install_dir/.installed-hash"
      '';
    };

  fetchStub = stubFetch {
    "sha256-old" = stubSensor "19401";
    "sha256-new" = stubSensor "19402";
  };

  # Driven directly in the test script, as an unprivileged user, to check the
  # state machine the icon renders. The icon itself is not tested here: drawing it
  # needs a graphical session and a StatusNotifierItem host, which is what
  # --print-state exists to sidestep.
  trayPkg = pkgs.callPackage ../pkgs/falcon-sensor-tray.nix { };

  # Writes credential files at runtime from /dev/urandom, so the values exist
  # nowhere in the Nix store and the leak assertions are meaningful rather than
  # circular.
  secretService = names: {
    description = "Provision test secrets";
    wantedBy = [ "multi-user.target" ];
    before = [
      "falcon-sensor-fetch.service"
      "falcon-sensor-configure.service"
    ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0700 /run/falcon-test-secrets
      hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
      ${lib.concatMapStringsSep "\n" (n: "hex 16 > /run/falcon-test-secrets/${n}") names}
      chmod 0400 /run/falcon-test-secrets/*
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "falcon-sensor-module";

  # Pinned by hash: the deterministic configuration the README recommends.
  nodes.pinned = {
    imports = [ self.nixosModules.default ];

    services.falcon-sensor = {
      enable = true;
      hash = "sha256-old";
      cid = "0123456789ABCDEF0123456789ABCDEF-01";
      provisioningTokenFile = "/run/falcon-test-secrets/provisioning-token";
      tags = [
        "Environment/Test"
        "Team/Platform"
      ];
      backend = "bpf";
      # Turns the status publisher on through its default, and brings up the
      # user service that would draw the icon in a real session.
      tray.enable = true;
      api = {
        package = fetchStub;
        clientIdFile = "/run/falcon-test-secrets/client-id";
        clientSecretFile = "/run/falcon-test-secrets/client-secret";
      };
    };

    systemd.services.falcon-test-secret = secretService [
      "client-id"
      "client-secret"
      "provisioning-token"
    ];
  };

  # Unpinned: tracks the update policy, and takes its CID and maintenance token
  # from files so every *File option is exercised somewhere.
  nodes.tracking = {
    imports = [ self.nixosModules.default ];

    services.falcon-sensor = {
      enable = true;
      cidFile = "/run/falcon-test-secrets/cid";
      maintenanceTokenFile = "/run/falcon-test-secrets/maintenance-token";
      # No tray on this one: the publisher stands on its own, and this is where
      # the opt-in identifiers are exercised.
      status = {
        enable = true;
        includeIdentifiers = true;
      };
      api = {
        package = fetchStub;
        clientIdFile = "/run/falcon-test-secrets/client-id";
        clientSecretFile = "/run/falcon-test-secrets/client-secret";
        updatePolicy = "platform_default";
      };
    };

    systemd.services.falcon-test-secret = secretService [
      "client-id"
      "client-secret"
      "cid"
      "maintenance-token"
    ];
  };

  testScript = ''
    import json

    pinned.wait_for_unit("multi-user.target")
    tracking.wait_for_unit("multi-user.target")

    with subtest("the sensor is fetched and bind-mounted into place"):
        pinned.wait_for_unit("falcon-sensor-fetch.service")
        pinned.succeed("mountpoint -q /opt/CrowdStrike")
        pinned.succeed("test -x /opt/CrowdStrike/falcond")
        pinned.succeed("grep -q 19401 /opt/CrowdStrike/version-marker")
        # A write through the hard-coded path must land in the state directory,
        # which is the single thing an impermanent host persists.
        pinned.succeed("echo written-through > /opt/CrowdStrike/probe")
        pinned.succeed("grep -q written-through /var/lib/falcon-sensor/opt/probe")

    with subtest("shipped files and subdirectories are writable"):
        pinned.succeed("echo rewritten > /opt/CrowdStrike/version-marker")
        pinned.succeed("touch /opt/CrowdStrike/subdir/written")

    with subtest("re-running the fetch does not stack mounts or re-download"):
        before = pinned.succeed("cat /run/stub-fetch-calls").count("downloaded")
        pinned.succeed("systemctl restart falcon-sensor-fetch.service")
        pinned.succeed("mountpoint -q /opt/CrowdStrike")
        count = pinned.succeed(
            "findmnt -n --target /opt/CrowdStrike -o TARGET | grep -c '^/opt/CrowdStrike$'"
        )
        assert count.strip() == "1", f"expected exactly one mount, got {count.strip()}"
        after = pinned.succeed("cat /run/stub-fetch-calls").count("downloaded")
        assert after == before, "a pinned host re-fetched a sensor it already had"
        pinned.succeed("grep -q written-through /opt/CrowdStrike/probe")

    with subtest("falconctl is configured with the expected arguments"):
        pinned.wait_for_unit("falcon-sensor-configure.service")
        ctl_log = pinned.succeed("cat /opt/CrowdStrike/falconctl.log")
        assert "--cid=0123456789ABCDEF0123456789ABCDEF-01" in ctl_log, ctl_log
        assert "--tags=Environment/Test,Team/Platform" in ctl_log, ctl_log
        assert "--backend=bpf" in ctl_log, ctl_log
        assert "--apd=true" in ctl_log, ctl_log

    with subtest("secrets are delivered and do not leak"):
        token = pinned.succeed("cat /run/falcon-test-secrets/provisioning-token").strip()
        ctl_log = pinned.succeed("cat /opt/CrowdStrike/falconctl.log")
        assert f"--provisioning-token={token}" in ctl_log, "token not delivered to falconctl"

        api_id = pinned.succeed("cat /run/falcon-test-secrets/client-id").strip()
        api_sec = pinned.succeed("cat /run/falcon-test-secrets/client-secret").strip()
        saw = pinned.succeed("cat /run/stub-fetch-saw").split()
        assert saw == [api_id, api_sec], f"fetch tool saw {saw}"

        for secret in (token, api_id, api_sec):
            pinned.fail(f"grep -r --binary-files=text -q {secret} /etc/systemd/system/")
            pinned.fail(f"journalctl -u falcon-sensor-fetch.service | grep -q {secret}")
            pinned.fail(f"journalctl -u falcon-sensor-configure.service | grep -q {secret}")

    with subtest("the sensor daemon runs"):
        pinned.wait_for_unit("falcon-sensor.service")
        pinned.succeed("systemctl is-active falcon-sensor.service")

    with subtest("the sensor's state is published for unprivileged readers"):
        pinned.succeed("systemctl start falcon-sensor-status.service")
        pinned.wait_for_file("/run/falcon-sensor/status.json")

        mode = pinned.succeed("stat -c %a /run/falcon-sensor/status.json").strip()
        assert mode == "644", f"status file is mode {mode}; a session must be able to read it"

        status = json.loads(pinned.succeed("cat /run/falcon-sensor/status.json"))
        assert status["sensor"]["queryable"] is True, status
        assert status["sensor"]["rfm"] is True, status
        assert status["sensor"]["rfm_reason"] == "Unsupported kernel", status
        assert status["sensor"]["registered"] is True, status
        assert status["sensor"]["backend"] == "bpf", status
        assert status["sensor"]["version"].startswith("8.10.0-"), status
        assert status["service"]["active_state"] == "active", status

        # World-readable file, so the identifiers stay out of it unless asked for.
        assert "identifiers" not in status, status

        # Same reasoning as the leak subtest above: nothing secret may reach a
        # file every local user can read.
        for secret in (token, api_id, api_sec):
            pinned.fail(f"grep -q {secret} /run/falcon-sensor/status.json")

        # The timer keeps it fresh, and a sensor restart refreshes it at once
        # rather than leaving a stale answer up for an interval.
        pinned.succeed("systemctl is-active falcon-sensor-status.timer")
        wants = pinned.succeed("systemctl show falcon-sensor.service --property=Wants --value")
        assert "falcon-sensor-status.service" in wants, wants

    with subtest("the tray resolves that state with no privileges at all"):
        tray = "${trayPkg}/bin/falcon-sensor-tray"

        def tray_state(machine, path):
            out = machine.succeed(
                f"su -s /bin/sh nobody -c '{tray} --status-file {path} --print-state'"
            )
            return out.splitlines()[0]

        # This host is in RFM, which is the case the icon exists for.
        assert tray_state(pinned, "/run/falcon-sensor/status.json") == "degraded"

        # Nothing publishing, and a publisher that has stopped publishing, are
        # both "unknown" -- never a reassuring stale answer.
        assert tray_state(pinned, "/run/falcon-sensor/absent.json") == "unknown"
        pinned.succeed(
            "sed -e 's/\"generated_epoch\": *[0-9]*/\"generated_epoch\": 1/'"
            " /run/falcon-sensor/status.json > /tmp/stale.json"
        )
        assert tray_state(pinned, "/tmp/stale.json") == "unknown"

        # The user service that would draw it in a session is wired up.
        pinned.succeed("test -e /etc/systemd/user/falcon-sensor-tray.service")

    with subtest("identifiers are published only where they were asked for"):
        tracking.succeed("systemctl start falcon-sensor-status.service")
        tracking.wait_for_file("/run/falcon-sensor/status.json")
        status = json.loads(tracking.succeed("cat /run/falcon-sensor/status.json"))
        assert status["identifiers"]["aid"] == "0123456789abcdef0123456789abcdef", status
        # The stub reports the CID as unset, which is the "... is not set."
        # parse path rather than a value.
        assert status["identifiers"]["cid"] is None, status
    with subtest("bumping the hash upgrades but keeps the sensor's identity"):
        # falconstore carries the AID; preserveFiles must carry it across.
        pinned.succeed("echo AID-I-MUST-KEEP > /opt/CrowdStrike/falconstore")
        pinned.succeed(
            "${fetchStub}/bin/falcon-sensor-fetch"
            " --client-id-file /run/falcon-test-secrets/client-id"
            " --client-secret-file /run/falcon-test-secrets/client-secret"
            " --install-dir /var/lib/falcon-sensor/opt --hash sha256-new"
            " --preserve 'falconstore falconstore.bak falconctl.conf'"
        )
        pinned.succeed("grep -q 19402 /opt/CrowdStrike/version-marker")
        pinned.succeed("grep -q AID-I-MUST-KEEP /opt/CrowdStrike/falconstore")
        # The previous version's stamped binaries are gone, not stranded.
        pinned.fail("test -e /opt/CrowdStrike/falconctl19401")


    with subtest("an unpinned host resolves through the API"):
        tracking.wait_for_unit("falcon-sensor-fetch.service")
        tracking.succeed("mountpoint -q /opt/CrowdStrike")
        # No hash, so the tool had to ask the API which sensor to install.
        tracking.succeed("grep -q resolved-via-api /run/stub-fetch-calls")

    with subtest("cidFile and maintenanceTokenFile are delivered from files"):
        tracking.wait_for_unit("falcon-sensor-configure.service")
        cid = tracking.succeed("cat /run/falcon-test-secrets/cid").strip()
        maint = tracking.succeed("cat /run/falcon-test-secrets/maintenance-token").strip()
        ctl_log = tracking.succeed("cat /opt/CrowdStrike/falconctl.log")
        assert f"--cid={cid}" in ctl_log, ctl_log
        assert f"--maintenance-token={maint}" in ctl_log, ctl_log

        # Tamper protection rejects every other change until the maintenance
        # token is set, so it must be the first falconctl call.
        lines = [x for x in ctl_log.splitlines() if x.strip()]
        assert "--maintenance-token=" in lines[0], f"maintenance token not first: {lines}"

        for secret in (cid, maint):
            tracking.fail(f"grep -r --binary-files=text -q {secret} /etc/systemd/system/")
            tracking.fail(f"journalctl -u falcon-sensor-configure.service | grep -q {secret}")
  '';
}
