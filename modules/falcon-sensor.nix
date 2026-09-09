{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.falcon-sensor;

  # The sensor hard-codes this. Everything below exists to make it a real
  # directory backed by cfg.statePath rather than a store symlink.
  installDir = "/opt/CrowdStrike";

  # Credential file options, in one place so the assertions and the
  # LoadCredential lists stay in sync. `name` is the systemd credential id.
  #
  # All of them are absolute paths to runtime files, typed as strings and never
  # as Nix paths: a `path` would be copied into the world-readable /nix/store
  # the moment it were interpolated.
  falconctlCredentials = builtins.filter (c: c.path != null) [
    {
      name = "cid";
      option = "cidFile";
      path = cfg.cidFile;
    }
    {
      name = "provisioning-token";
      option = "provisioningTokenFile";
      path = cfg.provisioningTokenFile;
    }
    {
      name = "maintenance-token";
      option = "maintenanceTokenFile";
      path = cfg.maintenanceTokenFile;
    }
  ];

  apiCredentials = builtins.filter (c: c.path != null) [
    {
      name = "client-id";
      option = "api.clientIdFile";
      path = cfg.api.clientIdFile;
    }
    {
      name = "client-secret";
      option = "api.clientSecretFile";
      path = cfg.api.clientSecretFile;
    }
  ];

  allCredentials = falconctlCredentials ++ apiCredentials;

  # Non-secret falconctl arguments. These come from options that already live in
  # the Nix store, so interpolating them into the script costs nothing. Secret
  # values are appended at runtime from $CREDENTIALS_DIRECTORY instead.
  staticArgs =
    lib.optional (cfg.cid != null && cfg.cidFile == null) "--cid=${cfg.cid}"
    ++ lib.optional (cfg.tags != [ ]) "--tags=${lib.concatStringsSep "," cfg.tags}"
    ++ lib.optional (cfg.backend != null) "--backend=${cfg.backend}"
    ++ lib.optional (cfg.cloud != null) "--cloud=${cfg.cloud}"
    ++ lib.optional (cfg.billing != null) "--billing=${cfg.billing}"
    ++ lib.optional (cfg.trace != "none") "--trace=${cfg.trace}"
    ++ (
      if cfg.proxy.enable then
        [
          "--apd=false"
          "--aph=${cfg.proxy.host}"
        ]
        ++ lib.optional (cfg.proxy.port != null) "--app=${toString cfg.proxy.port}"
      else
        [ "--apd=true" ]
    )
    ++ cfg.extraFalconctlArgs;

  # The RuntimeDirectory= holding cfg.status.path, derived rather than repeated so
  # the option and the unit cannot drift apart.
  statusRuntimeDir = lib.removePrefix "/run/" (builtins.dirOf cfg.status.path);

  isAbsolute = p: lib.hasPrefix "/" p;
  inStore = p: lib.hasPrefix builtins.storeDir p;
in
{
  options.services.falcon-sensor = {
    enable = lib.mkEnableOption ''
      the CrowdStrike Falcon sensor.

      The sensor is proprietary and sits behind an authenticated API, so each
      host downloads it itself using {option}`api.clientIdFile` and
      {option}`api.clientSecretFile`. Set {option}`hash` to pin one exact
      sensor across the fleet.

      Note that the sensor validates the running kernel against CrowdStrike's
      supported-kernel list and falls back to Reduced Functionality Mode (RFM)
      when it is not on that list -- which is usually the case for NixOS
      kernels. RFM still reports heartbeats and asset inventory, but performs no
      detection or prevention. Check with `falconctl -g --rfm-state`
    '';

    hash = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "sha256-RVNTBhFgWCM2y2bT4POM6btnvXiOFReoL1LvODFvVs8=";
      description = ''
        The sensor to install, as the SRI hash of its `.deb`. Bump this to
        upgrade.

        CrowdStrike's download endpoint is keyed by that same SHA-256
        (`?id=<sha256>`), so this one value both selects the installer and
        verifies it -- there is nothing else to pin.

        List what your tenant can install, with the hash to paste here:

        ```
        nix run github:lcleveland/falcon-sensor#find-sensor -- \
          --client-id-file /run/secrets/falcon-api-client-id \
          --client-secret-file /run/secrets/falcon-api-client-secret
        ```

        Left null, the host installs whatever {option}`api.updatePolicy`
        resolves to, or the newest available if that is unset too. That is
        convenient but non-deterministic: two hosts rebuilt on different days
        can end up on different sensors, and every boot has to ask the API which
        one to use. Pinning is recommended.
      '';
    };

    api = {
      clientIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/secrets/falcon-api-client-id";
        description = ''
          Absolute path to a runtime file holding the CrowdStrike API client id.
          Loaded via systemd credentials.
        '';
      };

      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/run/secrets/falcon-api-client-secret";
        description = ''
          Absolute path to a runtime file holding the CrowdStrike API client
          secret. The client needs the "Sensor Download: read" scope, plus
          "Sensor update policies: read" if {option}`updatePolicy` is set --
          and nothing else.

          Loaded via systemd credentials, so the value never enters the Nix
          store, the unit file or the journal.
        '';
      };

      cloud = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "us-2";
        description = ''
          Falcon cloud region for the API. Left null, the region is discovered
          from the `X-Cs-Region` header.
        '';
      };

      updatePolicy = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "platform_default";
        description = ''
          Resolve the sensor version from this sensor update policy. Only
          consulted when {option}`hash` is null. Requires the "Sensor update
          policies: read" scope.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.falcon-sensor-fetch or (pkgs.callPackage ../pkgs/falcon-sensor-fetch.nix { });
        defaultText = lib.literalExpression "pkgs.falcon-sensor-fetch";
        description = ''
          The tool that talks to the API and installs the sensor. It also
          carries the interpreter and library paths used to patch the fetched
          binaries for this host.
        '';
      };
    };

    statePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/falcon-sensor";
      description = ''
        Directory holding the sensor itself and all of its mutable state: its
        device identity (`falconstore`, which carries the AID), the
        configuration `falconctl` writes, and the channel files the sensor
        downloads to extend kernel support.

        The sensor hard-codes ${installDir}, so the module keeps the real
        directory at `''${statePath}/opt` and bind-mounts it onto that path (see
        falcon-sensor-fetch.service for why it must be a bind mount and not a
        symlink).

        On an impermanent / tmpfs-root host this is the one and only path to
        persist -- e.g. with nix-community/impermanence:

          environment.persistence."/persist".directories = [ "/var/lib/falcon-sensor" ];

        Nothing under /opt needs persisting. Without persistence the sensor
        loses its AID on every boot and re-registers as a brand-new host,
        re-downloads every channel file, and re-downloads the installer itself.
      '';
    };

    persistedPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = [ cfg.statePath ];
      defaultText = lib.literalExpression "[ config.services.falcon-sensor.statePath ]";
      description = ''
        Paths that must survive a wipe of the root filesystem, for hosts using
        impermanence. Read-only; exposed so a configuration can feed it into
        whatever persistence layer it uses, e.g.

          environment.persistence."/persist".directories =
            config.services.falcon-sensor.persistedPaths;

        The module deliberately does not set `environment.persistence` itself:
        impermanence asserts on duplicate paths, so a module that adds a path
        the user has also listed breaks evaluation.
      '';
    };

    cid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "0123456789ABCDEF0123456789ABCDEF-01";
      description = ''
        Customer ID (CID), in `<32 hex>-<2 hex checksum>` form. It identifies
        the tenant; it does not authenticate, so for most organisations keeping
        it in the Nix store is acceptable. Use {option}`cidFile` instead if
        yours is treated as sensitive. `find-sensor` prints the CID for the
        credentials it authenticated with.
      '';
    };

    cidFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/falcon-cid";
      description = ''
        Absolute path to a runtime file containing the CID. Takes precedence
        over {option}`cid`. Loaded via systemd credentials at service start; the
        value never enters the Nix store, the unit file, or the journal.
      '';
    };

    provisioningTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/falcon-provisioning-token";
      description = ''
        Absolute path to a runtime file containing the installation/provisioning
        token, for tenants that require one to register a host. Loaded via
        systemd credentials. There is deliberately no plaintext equivalent --
        this one is a real secret.
      '';
    };

    maintenanceTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/falcon-maintenance-token";
      description = ''
        Absolute path to a runtime file containing the maintenance token. Only
        needed when sensor tamper protection is enabled, in which case
        reconfiguring or removing the sensor requires it. Applied before any
        other `falconctl` change. Loaded via systemd credentials.
      '';
    };

    preserveFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "falconstore"
        "falconstore.bak"
        "falconctl.conf"
      ];
      description = ''
        Basenames under {option}`statePath`/opt carried across an in-place
        sensor upgrade rather than being replaced from the new installer.

        `falconstore` holds the Agent ID. Replacing it on a version bump would
        discard the host's identity and force a re-registration -- destroying
        the very thing persisting {option}`statePath` exists to protect.
        Anything listed here is still created on first install.
      '';
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "Environment/Production"
        "Team/Platform"
      ];
      description = ''
        Sensor grouping tags. CrowdStrike caps the combined, comma-joined
        string at 256 characters.
      '';
    };

    backend = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "auto"
          "bpf"
          "kernel"
        ]
      );
      default = "bpf";
      description = ''
        Sensor backend. `bpf` is the default and the right choice on NixOS: it
        runs in user space against the kernel's eBPF interface and has far
        looser kernel requirements than `kernel`, which wants a kernel module
        built for a kernel on CrowdStrike's supported list. Set to `null` to
        leave the sensor's own default alone.
      '';
    };

    cloud = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "us-2";
      description = ''
        Falcon cloud region the *sensor* should report to. Distinct from
        {option}`api.cloud`, which is where the installer is downloaded from.
        Leave null to let the sensor pick it from the CID.
      '';
    };

    billing = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "default"
          "metered"
        ]
      );
      default = null;
      description = "Billing mode. `metered` is for ephemeral cloud workloads.";
    };

    trace = lib.mkOption {
      type = lib.types.enum [
        "none"
        "err"
        "warn"
        "info"
        "debug"
      ];
      default = "none";
      description = "Sensor log verbosity.";
    };

    autoRemoveAid = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Clear the Agent ID before configuring the sensor, so the host registers
        as a new device on next start. This is what you want when baking a
        golden image or a VM template: cloning a host whose {option}`statePath`
        already holds an AID makes every clone report as the same device.

        Leave this off for ordinary hosts -- it discards the identity that
        persisting {option}`statePath` exists to preserve.
      '';
    };

    pidFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/run/falcond.pid";
      description = ''
        PID file for the forking daemon, or null to let systemd determine the
        main process itself. The default is the path CrowdStrike's own unit
        uses.

        If the service fails to start with `Can't open PID file ... after
        start`, falcond is writing its PID somewhere else -- setting this to
        null is the safe fallback.
      '';
    };

    restart = lib.mkOption {
      type = lib.types.enum [
        "no"
        "on-failure"
        "always"
      ];
      default = "on-failure";
      description = ''
        systemd restart policy. CrowdStrike's own unit uses `no`: the sensor
        handles its own degraded states, including dropping into Reduced
        Functionality Mode rather than exiting. `on-failure` is used here so a
        crashed security agent comes back; set this to `no` to match the vendor
        exactly.
      '';
    };

    proxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Route sensor traffic through an HTTP proxy. When false the sensor is
          explicitly told not to use a proxy (`--apd=true`).
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "proxy.example.com";
        description = "Proxy hostname.";
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        example = 3128;
        description = "Proxy port.";
      };
    };

    extraFalconctlArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--capture-provisioning=true" ];
      description = ''
        Extra arguments appended to the `falconctl -s -f` invocation. Escape
        hatch for settings this module does not model -- the real falconctl also
        accepts `--capture-provisioning`, `--expedite-provisioning`,
        `--linked-aid`, `--fkm`, `--k8s-cluster-id`, `--no-rtr` and `--feature`.
        Do not put secrets here: the value lands in the Nix store.
      '';
    };

    status = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.tray.enable;
        defaultText = lib.literalExpression "config.services.falcon-sensor.tray.enable";
        description = ''
          Publish the sensor's state to {option}`status.path`, as JSON, on a timer.

          `falconctl` is root-only, so nothing in a user session -- a tray icon, a
          status bar, a script running as a normal user -- can ask the sensor how
          it is doing. This runs `falconctl -g` as root and leaves the answer in a
          world-readable file for them to read instead.

          The file carries the sensor version, the unit's state, whether the host
          has registered, and the RFM state and reason. It carries no secrets: the
          Agent ID and the CID appear only under
          {option}`status.includeIdentifiers`.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = ''
          Seconds between refreshes of {option}`status.path`.

          The value is recorded in the file itself, so a reader can tell a current
          answer from a stale one: the tray reports "unknown" once three intervals
          have passed without a refresh, rather than a reassuring but stale
          "protected".
        '';
      };

      includeIdentifiers = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Also publish the Agent ID and the CID in {option}`status.path`.

          Off by default: that file is readable by every local user, while this
          module otherwise goes to some length to keep the CID out of
          world-readable places (see {option}`cidFile`). Registration state is
          published either way, derived from whether an AID exists rather than
          from its value.
        '';
      };

      path = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "/run/falcon-sensor/status.json";
        description = ''
          Where the published status lands. Read-only; exposed so a status bar can
          be pointed at it without hardcoding the path -- e.g. a waybar
          `custom/falcon` module reading it with `jq`.

          Under /run on purpose: it is derived state, meaningless after a reboot,
          and nothing here needs persisting.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.falcon-sensor-status or (pkgs.callPackage ../pkgs/falcon-sensor-status.nix { });
        defaultText = lib.literalExpression "pkgs.falcon-sensor-status";
        description = "The tool that queries `falconctl` and writes {option}`status.path`.";
      };
    };

    tray = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Show the sensor's state as a tray icon in the user's session, from a
          `graphical-session.target` user service.

          CrowdStrike ships no GUI for Linux, so this is a small
          StatusNotifierItem of this module's own: it appears in whatever tray the
          session already has and renders {option}`status.path`. Four states --
          protected, degraded (in RFM, or not yet registered), not running, and
          unknown (nothing is publishing a status). Clicking it shows the version,
          the unit state and the RFM reason.

          Strictly read-only: nothing in it can start, stop or reconfigure the
          sensor, so no privilege over the security agent is handed to the session.

          Off by default; this module's usual host is headless.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.falcon-sensor-tray or (pkgs.callPackage ../pkgs/falcon-sensor-tray.nix { });
        defaultText = lib.literalExpression "pkgs.falcon-sensor-tray";
        description = "The tray icon program, which also carries its own icons.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.cid != null || cfg.cidFile != null;
        message = ''
          services.falcon-sensor: set either `cid` or `cidFile`. Without a CID
          the sensor cannot register with your tenant. `find-sensor` prints the
          CID for your API credentials.
        '';
      }
      {
        assertion = cfg.api.clientIdFile != null && cfg.api.clientSecretFile != null;
        message = ''
          services.falcon-sensor needs both `api.clientIdFile` and
          `api.clientSecretFile` -- the sensor is behind an authenticated API
          and the host cannot download it without them.

          Create an API client in the Falcon console with the
          "Sensor Download: read" scope, put the id and secret in two files
          managed by sops-nix or agenix, and point these options at them.
        '';
      }
      {
        assertion = lib.stringLength (lib.concatStringsSep "," cfg.tags) <= 256;
        message = "services.falcon-sensor.tags: the comma-joined tag string exceeds CrowdStrike's 256-character limit.";
      }
      {
        assertion = cfg.proxy.enable -> cfg.proxy.host != "";
        message = "services.falcon-sensor.proxy.host must be set when proxy.enable is true.";
      }
      {
        assertion = cfg.tray.enable -> cfg.status.enable;
        message = ''
          services.falcon-sensor.tray.enable needs status.enable: the tray renders
          ${cfg.status.path} and cannot read falconctl itself -- it runs as an
          unprivileged user, and falconctl is root-only. Leave status.enable at its
          default, or set it to true.
        '';
      }
    ]
    ++ map (c: {
      assertion = isAbsolute c.path;
      message = "services.falcon-sensor.${c.option} must be an absolute path to a runtime file, got '${c.path}'.";
    }) allCredentials
    ++ map (c: {
      # A Nix path literal would have been copied into the world-readable store
      # by the time we see it here, so reject anything that lives there.
      assertion = !inStore c.path;
      message = ''
        services.falcon-sensor.${c.option} points into ${builtins.storeDir}
        ('${c.path}'), which is world-readable -- the secret is already exposed.
        Pass a runtime path as a string instead, e.g. "/run/secrets/falcon-cid"
        from sops-nix or agenix.
      '';
    }) allCredentials;

    warnings =
      lib.optional (cfg.backend == "kernel") ''
        services.falcon-sensor.backend is "kernel", which needs a kernel module
        matching a kernel on CrowdStrike's supported list. NixOS kernels are
        generally not on it. Use "bpf" unless you have confirmed otherwise with
        falcon-kernel-check.
      ''
      ++ lib.optional cfg.autoRemoveAid ''
        services.falcon-sensor.autoRemoveAid is enabled: the Agent ID is cleared
        on every start, so this host re-registers as a new device each boot.
        That is correct for golden images, but it defeats persisting
        ${cfg.statePath}.
      ''
      ++ lib.optional (cfg.hash == null) ''
        services.falcon-sensor.hash is unset, so this host installs whatever the
        API offers at the time it first boots. Two hosts built from the same
        configuration can end up on different sensor versions, and every boot
        must reach the API to find out which. Pin it -- see `find-sensor`.
      '';

    environment.systemPackages = [
      cfg.api.package
    ]
    # `sudo falcon-sensor-status` is a useful thing to have next to falconctl.
    ++ lib.optional cfg.status.enable cfg.status.package
    # Also puts the tray's icons in the system icon theme, for hosts that
    # resolve tray icon names through it rather than through IconThemePath.
    ++ lib.optional cfg.tray.enable cfg.tray.package;

    # Fetch the sensor, and relocate its state. This is also the reason the
    # module works on a tmpfs root.
    #
    # falcond hard-codes ${installDir} for both its binaries and its state, and
    # a symlink there is not good enough: an EDR resolves its own and its peers'
    # identities through /proc/<pid>/exe, and the .deb installs everything
    # read-only while the sensor writes into its own subdirectories at runtime.
    # The files must be REAL, WRITABLE files at the hard-coded path.
    #
    # So: the real directory lives at ''${statePath}/opt, and is bind-mounted
    # onto ${installDir}. A bind mount, unlike a symlink, preserves the visible
    # path. Every mutable file then lives under the one statePath, so persisting
    # that single directory is all an impermanent host has to do, and /opt stays
    # fully disposable.
    systemd.services.falcon-sensor-fetch = {
      description = "Fetch and install the CrowdStrike Falcon sensor";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [
        "falcon-sensor-configure.service"
        "falcon-sensor.service"
      ];
      path = [ pkgs.util-linux ]; # mount, mountpoint
      unitConfig.RequiresMountsFor = cfg.statePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = map (c: "${c.name}:${c.path}") apiCredentials;
        # A transient DNS failure at boot should not leave the host without a
        # sensor until the next reboot.
        Restart = "on-failure";
        RestartSec = 300;
      };
      script = ''
        set -eu
        app="${cfg.statePath}/opt"
        dst="${installDir}"

        # 0755: falconctl is run interactively by admins and the sensor's own
        # tooling walks this tree. No secret ever lives here -- they arrive
        # through systemd credentials.
        install -d -m 0755 "${cfg.statePath}" "$app"

        # With `hash` set this exits before touching the network when the right
        # sensor is already installed, so steady-state boots do no I/O.
        ${lib.getExe cfg.api.package} \
          --client-id-file "$CREDENTIALS_DIRECTORY/client-id" \
          --client-secret-file "$CREDENTIALS_DIRECTORY/client-secret" \
          --install-dir "$app" \
          --preserve ${lib.escapeShellArg (lib.concatStringsSep " " cfg.preserveFiles)} \
          ${lib.optionalString (cfg.hash != null) "--hash ${cfg.hash}"} \
          ${lib.optionalString (cfg.api.cloud != null) "--cloud ${cfg.api.cloud}"} \
          ${lib.optionalString (cfg.api.updatePolicy != null) "--update-policy ${cfg.api.updatePolicy}"}

        # Bind-mount onto the path the sensor hard-codes. Guarded so that a
        # nixos-rebuild switch which re-runs this unit does not stack mounts.
        install -d -m 0755 "$dst"
        if ! mountpoint -q "$dst"; then
          mount --bind "$app" "$dst"
        fi
      '';
    };

    # Declarative sensor configuration.
    #
    # Secrets are read from root-only systemd credential files at runtime --
    # their values never enter the unit definition, the Nix store, or
    # nixos-rebuild logs. falconctl only accepts them on its own argv, so the
    # arguments are assembled inside the script, keeping the exposure to a
    # single short-lived root process.
    systemd.services.falcon-sensor-configure = {
      description = "Configure the CrowdStrike Falcon sensor";
      wantedBy = [ "multi-user.target" ];
      after = [ "falcon-sensor-fetch.service" ];
      requires = [ "falcon-sensor-fetch.service" ];
      before = [ "falcon-sensor.service" ];
      unitConfig.RequiresMountsFor = cfg.statePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = installDir;
        LoadCredential = map (c: "${c.name}:${c.path}") falconctlCredentials;
      };
      script = ''
        set -eu
        falconctl="${installDir}/falconctl"

        ${lib.optionalString (cfg.maintenanceTokenFile != null) ''
          # Tamper protection rejects every other change until this is set.
          "$falconctl" -s -f \
            "--maintenance-token=$(cat "$CREDENTIALS_DIRECTORY/maintenance-token")"
        ''}

        ${lib.optionalString cfg.autoRemoveAid ''
          # Golden-image support: drop the Agent ID so this host registers anew.
          "$falconctl" -d -f --aid || true
        ''}

        args=(${lib.escapeShellArgs staticArgs})

        ${lib.optionalString (cfg.cidFile != null) ''
          args+=("--cid=$(cat "$CREDENTIALS_DIRECTORY/cid")")
        ''}
        ${lib.optionalString (cfg.provisioningTokenFile != null) ''
          args+=("--provisioning-token=$(cat "$CREDENTIALS_DIRECTORY/provisioning-token")")
        ''}

        "$falconctl" -s -f "''${args[@]}"
      '';
    };

    systemd.services.falcon-sensor = {
      description = "CrowdStrike Falcon Sensor";
      wantedBy = [ "multi-user.target" ];
      after = [
        "falcon-sensor-fetch.service"
        "falcon-sensor-configure.service"
        "network-online.target"
      ];
      requires = [
        "falcon-sensor-fetch.service"
        "falcon-sensor-configure.service"
      ];
      wants = [ "network-online.target" ];
      unitConfig = {
        RequiresMountsFor = cfg.statePath;
        Documentation = [ "https://falcon.crowdstrike.com/documentation" ];
      };

      serviceConfig = {
        # Transcribed from the falcon-sensor.service that ships in the 8.10
        # .deb. Deliberately NOT set, despite every community NixOS module
        # setting it: WorkingDirectory. The vendor unit does not, and falcond
        # finds its files through the absolute /opt/CrowdStrike path anyway.
        Type = "forking";
        ExecStart = "${installDir}/falcond";

        # The vendor's own preflight: fails the unit when no CID is set, rather
        # than letting falcond come up unable to register.
        ExecStartPre = "${installDir}/falconctl -g --cid";

        # falcond forks helpers that must not be torn down out from under it,
        # and the sensor asks for a full 60s to shut down cleanly.
        KillMode = "control-group";
        KillSignal = "SIGTERM";
        TimeoutStopSec = "60s";

        # The sensor manages its own cgroup subtree.
        Delegate = true;

        Restart = cfg.restart;

        # An EDR needs to see the whole host: every process, every mount, and
        # unrestricted egress to the Falcon cloud. Sandboxing it defeats the
        # point, so this is deliberately minimal.
        ProtectSystem = false;
        ProtectHome = false;
        PrivateTmp = false;
      }
      // lib.optionalAttrs (cfg.pidFile != null) { PIDFile = cfg.pidFile; }
      // lib.optionalAttrs (cfg.restart != "no") { RestartSec = 5; };
    };

    # Make the sensor's state readable without root.
    #
    # falconctl is mode 0500 and owned by root, so a session cannot ask the sensor
    # anything: the tray icon, a status bar, an unprivileged health check all get
    # "Permission denied". Rather than handing any of them a way to run falconctl
    # -- sudo rules, a setuid wrapper, a polkit action on the unit -- one root
    # oneshot asks and publishes the answer, and everything else reads a file.
    #
    # That keeps the privileged surface at exactly one program which only ever
    # performs `falconctl -g` reads, and it means a status bar needs no privileges
    # at all. See tools/falcon-sensor-status.sh for what does and does not go in
    # the file.
    systemd.services.falcon-sensor-status = lib.mkIf cfg.status.enable {
      description = "Publish the CrowdStrike Falcon sensor's state";
      # Pulled in by the sensor itself, so starting or restarting the sensor
      # refreshes the file at once instead of leaving a stale answer up for a
      # timer interval.
      wantedBy = [ "falcon-sensor.service" ];
      # falconctl does not exist until the fetch has bind-mounted it into place.
      after = [ "falcon-sensor-fetch.service" ];
      requires = [ "falcon-sensor-fetch.service" ];
      unitConfig.RequiresMountsFor = cfg.statePath;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.concatStringsSep " " (
          [
            (lib.getExe cfg.status.package)
            "--install-dir ${installDir}"
            "--output ${cfg.status.path}"
            "--interval ${toString cfg.status.interval}"
          ]
          ++ lib.optional cfg.status.includeIdentifiers "--identifiers"
        );

        # 0755 on the directory and 0644 on the file: the whole point is that an
        # unprivileged reader can get at it. RuntimeDirectoryPreserve is not
        # optional here -- without it systemd removes the directory the moment
        # this oneshot exits, taking the file with it.
        RuntimeDirectory = statusRuntimeDir;
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = "yes";

        # Kept to the two directives that cannot change what a vendor binary can
        # see of the system it inspects. Locking this down further -- an address
        # family allowlist, a namespaced /proc -- risks falconctl quietly
        # answering "unset" for everything, which the tray would faithfully
        # display as a healthy sensor with no version.
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.falcon-sensor-status = lib.mkIf cfg.status.enable {
      description = "Refresh the published CrowdStrike Falcon sensor state";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "${toString cfg.status.interval}s";
        # A status display does not need second-accurate timers, and this lets
        # systemd batch the wakeups.
        AccuracySec = "10s";
        Unit = "falcon-sensor-status.service";
      };
    };

    # The tray icon, in the user's session.
    #
    # Its lifecycle belongs to systemd rather than to an XDG autostart entry, so
    # it comes back with the session and gets restarted if it dies -- the same
    # reasoning as the netskope module's stagentui unit, except that there is no
    # vendor UI to run here and this is our own StatusNotifierItem.
    systemd.user.services.falcon-sensor-tray = lib.mkIf cfg.tray.enable {
      description = "CrowdStrike Falcon sensor tray icon";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.tray.package} --status-file ${cfg.status.path}";
        # A tray host that is not up yet, or a shell being restarted, should not
        # leave the session without an icon.
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
