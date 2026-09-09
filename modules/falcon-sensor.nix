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
  # LoadCredential list stay in sync. `name` is the systemd credential id.
  credentials = [
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

  setCredentials = builtins.filter (c: c.path != null) credentials;

  # The API credentials belong to the refresh unit, not the configure unit, but
  # they follow the same convention and want the same path assertions.
  apiCredentials = builtins.filter (c: c.path != null) [
    {
      name = "client-id";
      option = "apiRefresh.clientIdFile";
      path = cfg.apiRefresh.clientIdFile;
    }
    {
      name = "client-secret";
      option = "apiRefresh.clientSecretFile";
      path = cfg.apiRefresh.clientSecretFile;
    }
  ];

  allCredentials = setCredentials ++ apiCredentials;

  # Non-secret falconctl arguments. These come from options that already live in
  # the Nix store, so interpolating them into the script costs nothing. Secret
  # values are appended at runtime from $CREDENTIALS_DIRECTORY instead -- see
  # the configure service.
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

  isAbsolute = p: lib.hasPrefix "/" p;
  inStore = p: lib.hasPrefix builtins.storeDir p;
in
{
  options.services.falcon-sensor = {
    enable = lib.mkEnableOption ''
      the CrowdStrike Falcon sensor.

      Note that the sensor validates the running kernel against CrowdStrike's
      supported-kernel list and falls back to Reduced Functionality Mode (RFM)
      when it is not on that list -- which is usually the case for NixOS
      kernels. RFM still reports heartbeats and asset inventory, but performs no
      detection or prevention. Check with `falcon-kernel-check`
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.falcon-sensor or (pkgs.callPackage ../pkgs/falcon-sensor.nix { });
      defaultText = lib.literalExpression "pkgs.falcon-sensor";
      description = ''
        The Falcon sensor package. The installer it is built from is
        proprietary and must be pinned first with `nix run .#update-sensor`,
        which fetches it from the CrowdStrike Sensor Download API.
      '';
    };

    statePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/falcon-sensor";
      description = ''
        Directory holding all of the sensor's mutable state: its device identity
        (`falconstore`, which carries the AID), the configuration `falconctl`
        writes, and the channel files the sensor downloads to extend kernel
        support.

        The sensor hard-codes ${installDir} and writes state there, so the
        module keeps the real directory at `''${statePath}/opt` and bind-mounts
        it onto that path (see falcon-sensor-setup.service for why it must be a
        bind mount and not a symlink).

        On an impermanent / tmpfs-root host this is the one and only path to
        persist -- e.g. with nix-community/impermanence:

          environment.persistence."/persist".directories = [ "/var/lib/falcon-sensor" ];

        Nothing under /opt needs persisting; it is refreshed from the Nix store
        on every activation. Without persistence the sensor loses its AID on
        every boot and re-registers as a brand-new host, and re-downloads every
        channel file.
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
        yours is treated as sensitive. `nix run .#update-sensor` prints the CID
        for the credentials it authenticated with.
      '';
    };

    cidFile = lib.mkOption {
      # NB: string, not path -- a `path` would be copied into the world-readable
      # /nix/store when interpolated. This is an absolute path resolved at runtime.
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

    useVendorUnit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use the `falcon-sensor.service` that ships inside the .deb instead of
        the one this module reconstructs, adding only the ordering this module
        needs as a drop-in.

        The module's own unit is a reconstruction from CrowdStrike's Linux
        documentation and the community NixOS modules -- accurate as far as
        anyone has published, but a guess about `Type`, `PIDFile` and `KillMode`
        all the same. The vendor unit is authoritative, and the bind mount means
        its hard-coded paths already resolve. Turn this on once you have
        confirmed the .deb actually ships a unit:

          ls ''${pkgs.falcon-sensor}/lib/systemd/system/

        It is off by default only because a .deb that installs its unit from a
        postinst script instead would leave you with no service at all.
      '';
    };

    pidFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/run/falcond.pid";
      description = ''
        PID file for the forking daemon, or null to let systemd determine the
        main process itself. Ignored when {option}`useVendorUnit` is set.

        If the service fails to start with `Can't open PID file ... after
        start`, falcond is writing its PID somewhere else (or not at all) --
        setting this to null is the safe fallback.
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
        systemd restart policy. Note that CrowdStrike's own unit uses `no`: the
        sensor handles its own degraded states, including dropping into Reduced
        Functionality Mode rather than exiting. `on-failure` is used here so a
        crashed security agent comes back, but set this to `no` to match the
        vendor exactly. Ignored when {option}`useVendorUnit` is set.
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
        Basenames under {option}`statePath`/opt that are never overwritten from
        the Nix store once they exist, even when the package changes.

        `falconstore` holds the Agent ID. If a sensor release ships that name in
        its own .deb, refreshing it on a version bump would discard the host's
        identity and force a re-registration -- destroying the very thing
        persisting {option}`statePath` exists to protect. Anything listed here
        is still created on first start, when it does not yet exist locally.
      '';
    };

    apiRefresh = {
      enable = lib.mkEnableOption ''
        fetching the sensor from the CrowdStrike API on the host itself, on a
        timer, instead of using the pinned {option}`package`.

        This is a real trade-off, not a free upgrade. It keeps hosts on whatever
        version your sensor update policy allows without a rebuild, but:

        - every host must hold Sensor Download API credentials, which can
          download installers for the whole tenant;
        - the installed sensor is no longer described by the system closure, so
          two hosts on the same NixOS generation can run different sensors;
        - the binaries are patched for this host at runtime rather than by
          `autoPatchelfHook` at build time.

        The pinned path is the default for those reasons. With this enabled,
        falcon-sensor-setup no longer populates the state directory from the Nix
        store -- falcon-sensor-refresh owns it -- so {option}`package` is used
        only for its metadata
      '';

      clientIdFile = lib.mkOption {
        # NB: string, not path -- see cidFile.
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
          secret. Needs the "Sensor Download: read" scope, plus "Sensor update
          policies: read" if {option}`updatePolicy` is set. Loaded via systemd
          credentials; the value never enters the Nix store, the unit file or
          the journal.
        '';
      };

      cloud = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "us-2";
        description = ''
          Falcon cloud region for the API. Left null, the region is discovered
          from the `X-Cs-Region` header on every run.
        '';
      };

      updatePolicy = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "platform_default";
        description = ''
          Take the sensor version from this sensor update policy rather than
          installing the newest available. Requires the "Sensor update
          policies: read" scope. This is how you keep a fleet on N-1 or N-2.
        '';
      };

      sensorVersion = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Pin an exact sensor version instead of tracking a policy.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        example = "weekly";
        description = ''
          `OnCalendar` expression for how often to check the API. The refresh is
          a no-op when the installed version already matches.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.falcon-update-sensor or (pkgs.callPackage ../pkgs/update-sensor.nix { });
        defaultText = lib.literalExpression "pkgs.falcon-update-sensor";
        description = "The updater used to fetch and install the sensor.";
      };
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
        Falcon cloud region the sensor should report to. Leave null to let the
        sensor pick it from the CID.
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
      description = ''
        Billing mode. `metered` is for ephemeral cloud workloads.
      '';
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
        golden image or a VM template: cloning a host whose
        {option}`statePath` already holds an AID makes every clone report as the
        same device in the console.

        Leave this off for ordinary hosts -- it discards the identity that
        persisting {option}`statePath` exists to preserve.
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
      example = [ "--rfm-reason" ];
      description = ''
        Extra arguments appended to the `falconctl -s -f` invocation. Escape
        hatch for settings this module does not model. Do not put secrets here:
        the value lands in the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.cid != null || cfg.cidFile != null;
        message = ''
          services.falcon-sensor: set either `cid` or `cidFile`. Without a CID
          the sensor cannot register with your tenant. `nix run .#update-sensor`
          prints the CID for your API credentials.
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
        assertion =
          cfg.apiRefresh.enable
          -> (cfg.apiRefresh.clientIdFile != null && cfg.apiRefresh.clientSecretFile != null);
        message = ''
          services.falcon-sensor.apiRefresh needs both `clientIdFile` and
          `clientSecretFile` -- the host cannot reach the Sensor Download API
          without them.
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
      ++ lib.optional (cfg.autoRemoveAid && cfg.statePath != null) ''
        services.falcon-sensor.autoRemoveAid is enabled: the Agent ID is cleared
        on every start, so this host re-registers as a new device each boot.
        That is correct for golden images, but it defeats persisting
        ${cfg.statePath}.
      '';

    environment.systemPackages = [ cfg.package ];

    # Pull in the vendor's own falcon-sensor.service; the drop-in below adds the
    # ordering this module needs without touching its settings.
    systemd.packages = lib.mkIf cfg.useVendorUnit [ cfg.package ];

    # State relocation, and the reason the module works on a tmpfs root.
    #
    # falcond hard-codes ${installDir} for both its binaries and its state, and
    # a store symlink there is not good enough: an EDR resolves its own and its
    # peers' identities through /proc/<pid>/exe, which would read back as a
    # /nix/store path. The shipped files must be REAL FILES at the hard-coded
    # path.
    #
    # So: keep the real directory at ''${statePath}/opt -- populated by copying
    # the shipped files out of the store, refreshed when the package changes --
    # and bind-mount it onto ${installDir}. A bind mount, unlike a symlink,
    # preserves the visible path.
    #
    # The payoff for impermanence is that every mutable file lives under the one
    # statePath, so persisting that single directory is all an impermanent host
    # has to do, and /opt stays fully disposable.
    systemd.services.falcon-sensor-setup = {
      description = "Prepare ${installDir} (Falcon sensor state relocation)";
      wantedBy = [ "multi-user.target" ];
      before = [
        "falcon-sensor-configure.service"
        "falcon-sensor.service"
      ];
      path = [ pkgs.util-linux ]; # mount, mountpoint
      unitConfig.RequiresMountsFor = cfg.statePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        ${lib.optionalString cfg.useVendorUnit ''
          # useVendorUnit relies on the .deb shipping its own unit. If it does
          # not, systemd.packages contributes nothing and there would be no
          # sensor at all -- a silent failure on a security agent. This cannot
          # be an eval-time assertion: probing the package's file tree from Nix
          # would force an import-from-derivation, building the sensor just to
          # evaluate the configuration.
          if [ ! -e "${cfg.package}/lib/systemd/system/falcon-sensor.service" ]; then
            echo "falcon-sensor: useVendorUnit is set but this package ships no" >&2
            echo "  lib/systemd/system/falcon-sensor.service. Unset it to use the" >&2
            echo "  module's own unit definition." >&2
            exit 1
          fi
        ''}

        src="${cfg.package}/opt/CrowdStrike"
        app="${cfg.statePath}/opt"
        dst="${installDir}"
        stamp="$app/.nix-generation"

        # 0755: falconctl is run interactively by admins and the sensor's own
        # tooling walks this tree. The secrets never live here -- they arrive
        # through systemd credentials.
        install -d -m 0755 "${cfg.statePath}" "$app"
        ${lib.optionalString cfg.apiRefresh.enable ''
          # apiRefresh owns this directory: falcon-sensor-refresh unpacks the
          # sensor it fetched straight into it, so populating from the store
          # here would clobber a newer sensor with the pinned one on every boot.
          echo "falcon-sensor: apiRefresh is enabled, leaving $app to falcon-sensor-refresh"
        ''}

        ${lib.optionalString (!cfg.apiRefresh.enable) ''

          # Refresh the shipped files whenever the package changes.
          #
          # Names listed in `preserveFiles` are never overwritten once they exist
          # locally: if a .deb ever ships falconstore or falconctl.conf, a naive
          # refresh would delete the Agent ID on every sensor upgrade, destroying
          # exactly what persisting statePath exists to protect. (Sensor 8.10
          # ships neither, so the default is inert there -- but it costs nothing
          # and a future release may differ.)
          #
          # The manifest exists because the sensor ships version-stamped names --
          # falconctl19402, KernelModuleArchive19402, falcon-aspm19402 -- behind
          # unversioned symlinks. Removing only the names present in the *new*
          # package would strand the previous version's files forever, and they
          # are large: a single stale generation is over 150 MB sitting in the
          # directory an impermanent host persists.
          preserve="${lib.concatStringsSep " " cfg.preserveFiles}"
          manifest="$app/.nix-manifest"

          if [ "$(cat "$stamp" 2>/dev/null || true)" != "$src" ]; then
            new_names="$app/.nix-manifest.new"
            : > "$new_names"

            for f in "$src"/*; do
              b="$(basename "$f")"
              printf '%s\n' "$b" >> "$new_names"
              case " $preserve " in
                *" $b "*)
                  if [ -e "$app/$b" ]; then
                    echo "falcon-sensor: keeping existing state file $b"
                    continue
                  fi
                  ;;
              esac
              rm -rf "$app/$b"
              cp -a "$f" "$app/$b"
            done

            # Drop anything the previous generation installed that this one no
            # longer ships. Only ever touches names we put there ourselves, so
            # runtime state the sensor created is never considered.
            if [ -f "$manifest" ]; then
              while IFS= read -r old; do
                [ -n "$old" ] || continue
                if ! grep -qxF -- "$old" "$new_names"; then
                  case " $preserve " in
                    *" $old "*) continue ;;
                  esac
                  echo "falcon-sensor: removing stale $old from the previous sensor version"
                  rm -rf "''${app:?}/$old"
                fi
              done < "$manifest"
            fi

            # The .deb ships everything read-only (dr-xr-xr-x / -r-xr-xr-x), and
            # the store copy is read-only again on top of that. The sensor writes
            # into its own subdirectories at runtime -- Packages/, ASPM/results,
            # ASPM/tmp, Falcon4IT/results -- so this has to be recursive; making
            # only the top level writable leaves those nested directories
            # unwritable and the sensor unable to work in them.
            chmod -R u+w "$app"

            mv -- "$new_names" "$manifest"
            printf %s "$src" > "$stamp"
          fi
        ''}


        # Bind-mount onto the path the sensor hard-codes. Guarded so that a
        # nixos-rebuild switch which re-runs this unit does not stack mounts.
        install -d -m 0755 "$dst"
        if ! mountpoint -q "$dst"; then
          mount --bind "$app" "$dst"
        fi
      '';
    };

    # Fetch the sensor from the CrowdStrike API on this host and unpack it into
    # the state directory. Only exists when apiRefresh is enabled; otherwise the
    # sensor comes from the pinned package and no API credentials are present.
    systemd.services.falcon-sensor-refresh = lib.mkIf cfg.apiRefresh.enable {
      description = "Fetch the CrowdStrike Falcon sensor from the API";
      wantedBy = [ "multi-user.target" ];
      after = [
        "falcon-sensor-setup.service"
        "network-online.target"
      ];
      requires = [ "falcon-sensor-setup.service" ];
      wants = [ "network-online.target" ];
      before = [
        "falcon-sensor-configure.service"
        "falcon-sensor.service"
      ];
      unitConfig.RequiresMountsFor = cfg.statePath;
      path = [ pkgs.systemd ]; # systemctl
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = map (c: "${c.name}:${c.path}") apiCredentials;
        # The API is rate-limited and a transient DNS failure at boot should not
        # leave the host without a sensor forever.
        Restart = "on-failure";
        RestartSec = 300;
      };
      script = ''
        set -eu

        # The install swaps the directory contents, so the daemon must not be
        # running out of it. At boot it never is; on a timer-driven upgrade it
        # is, and gets started again below.
        was_active=0
        if systemctl is-active --quiet falcon-sensor.service; then
          was_active=1
          systemctl stop falcon-sensor.service
        fi

        ${lib.getExe cfg.apiRefresh.package} \
          --client-id-file "$CREDENTIALS_DIRECTORY/client-id" \
          --client-secret-file "$CREDENTIALS_DIRECTORY/client-secret" \
          --install-dir "${cfg.statePath}/opt" \
          ${lib.optionalString (cfg.apiRefresh.cloud != null) "--cloud ${cfg.apiRefresh.cloud}"} \
          ${
            lib.optionalString (
              cfg.apiRefresh.updatePolicy != null
            ) "--update-policy ${cfg.apiRefresh.updatePolicy}"
          } \
          ${lib.optionalString (
            cfg.apiRefresh.sensorVersion != null
          ) "--sensor-version ${cfg.apiRefresh.sensorVersion}"}

        if [ "$was_active" -eq 1 ]; then
          systemctl start falcon-sensor.service
        fi
      '';
    };

    systemd.timers.falcon-sensor-refresh = lib.mkIf cfg.apiRefresh.enable {
      description = "Check the CrowdStrike API for a newer Falcon sensor";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.apiRefresh.interval;
        # Endpoints all waking at once would hammer the API; the check is cheap
        # but the download is not.
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
    # Declarative sensor configuration.
    #
    # Secrets are read from root-only systemd credential files at runtime --
    # their values never enter the unit definition, the Nix store, or
    # nixos-rebuild logs. falconctl itself only accepts them on its own argv, so
    # the arguments are assembled inside the script and passed directly, keeping
    # the exposure to a single short-lived root process.
    systemd.services.falcon-sensor-configure = {
      description = "Configure the CrowdStrike Falcon sensor";
      wantedBy = [ "multi-user.target" ];
      after = [
        "falcon-sensor-setup.service"
      ]
      ++ lib.optional cfg.apiRefresh.enable "falcon-sensor-refresh.service";
      requires = [
        "falcon-sensor-setup.service"
      ]
      ++ lib.optional cfg.apiRefresh.enable "falcon-sensor-refresh.service";
      before = [ "falcon-sensor.service" ];
      unitConfig.RequiresMountsFor = cfg.statePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = installDir;
        LoadCredential = map (c: "${c.name}:${c.path}") setCredentials;
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
        "falcon-sensor-setup.service"
        "falcon-sensor-configure.service"
        "network-online.target"
      ];
      requires = [
        "falcon-sensor-setup.service"
        "falcon-sensor-configure.service"
      ];
      wants = [ "network-online.target" ];

      # With useVendorUnit the sensor's own unit file provides Type/ExecStart/
      # PIDFile/KillMode and this becomes a drop-in that only adds ordering.
      overrideStrategy = lib.mkIf cfg.useVendorUnit "asDropin";

      unitConfig = {
        RequiresMountsFor = cfg.statePath;
      }
      // lib.optionalAttrs (!cfg.useVendorUnit) {
        Documentation = [ "https://falcon.crowdstrike.com/documentation" ];
      };

      serviceConfig =
        lib.optionalAttrs (!cfg.useVendorUnit) {
          # Transcribed from the falcon-sensor.service that ships in the 8.10
          # .deb, which is kept at ${cfg.package}/lib/systemd/system for
          # comparison. Setting useVendorUnit uses that file directly and makes
          # this block moot -- prefer it if your .deb ships one.
          #
          # Deliberately NOT set, despite every community NixOS module setting
          # it: WorkingDirectory. The vendor unit does not, and falcond finds
          # its files through the absolute /opt/CrowdStrike path either way.
          Type = "forking";
          ExecStart = "${installDir}/falcond";

          # The vendor's own preflight: fails the unit when no CID is set,
          # rather than letting falcond come up unable to register.
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
        // lib.optionalAttrs (!cfg.useVendorUnit && cfg.pidFile != null) {
          PIDFile = cfg.pidFile;
        }
        // lib.optionalAttrs (!cfg.useVendorUnit && cfg.restart != "no") {
          RestartSec = 5;
        };
    };
  };
}
