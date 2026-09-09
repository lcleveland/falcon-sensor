# falcon-sensor

The CrowdStrike Falcon sensor for Linux, packaged as a NixOS module.

Two things make this awkward on NixOS, and this flake exists to handle both:

- **The installer is behind an authenticated API.** It cannot be `fetchurl`'d.
  `nix run .#update-sensor` talks to the CrowdStrike Sensor Download API, picks a suitable
  `.deb`, verifies it, adds it to the Nix store, and records the pin in `pkgs/sources.json`. After that
  the build is pure, cacheable and offline.
- **The sensor hard-codes `/opt/CrowdStrike` and writes its identity there.** On a tmpfs root
  that is lost every boot. The module relocates all mutable state to a single `/var/lib`
  directory and bind-mounts it into place, so an impermanent host has exactly one path to
  persist.

> **Unfree and non-redistributable.** Set `nixpkgs.config.allowUnfree = true` (or an
> `allowUnfreePredicate`) for `falcon-sensor`. Never commit the `.deb`; `.gitignore` blocks it.

## Usage

```nix
{
  inputs.falcon-sensor.url = "github:you/falcon-sensor";

  # in your host configuration
  imports = [ inputs.falcon-sensor.nixosModules.default ];

  services.falcon-sensor = {
    enable = true;
    cid = "0123456789ABCDEF0123456789ABCDEF-01";
    provisioningTokenFile = "/run/secrets/falcon-provisioning-token";
    tags = [ "Environment/Production" "Team/Platform" ];
  };
}
```

The module's `package` default builds from `pkgs/sources.json`, so pin a sensor first.

## Pinning a sensor

Create an API client in the Falcon console (**Support and resources → Resources and tools → API
clients and keys → Create API client**). You need the Falcon Administrator role. Give it the
**Sensor Download: read** scope. Add **Sensor update policies: read** only if you intend to
use `--update-policy`.

```bash
nix run .#update-sensor -- \
  --client-id-file     /run/secrets/falcon-api-client-id \
  --client-secret-file /run/secrets/falcon-api-client-secret

git add pkgs/sources.json && git commit -m "falcon-sensor: pin 8.x.x"
```

The updater discovers your cloud region from the `X-Cs-Region` header, prints your CID, selects
the newest Debian/Ubuntu `.deb` for the architecture, verifies the download against the SHA-256
the API declared, runs `nix-store --add-fixed sha256` on it, and records the pin in
`pkgs/sources.json`. That file holds only properties of the installer itself — name, version,
hash, target OS and architecture. Nothing in it is secret or specific to your tenant, and it is
what makes the build reproducible.

Pins accumulate rather than overwrite, keyed by Debian version, so a fleet mid-rollout across
two sensor versions can select either:

```nix
services.falcon-sensor.package = pkgs.falcon-sensor.override { version = "8.09.0-19204"; };
```

With no `version`, the newest pin in the table is used.

Useful flags: `--update-policy platform_default` to take the version from a sensor update
policy, `--sensor-version` to pin exactly, `--os`/`--os-version`/`--os-regex` to change the
distro selection, `--filter` to replace the generated FQL outright, `--sources` to write
somewhere else, and `--dry-run` to see what would be selected. `--help` lists everything.

Because the pin is a flat SHA-256, the store path is reproducible: another machine either
already has the blob or runs the updater once. No build ever needs credentials or network.

If you downloaded the `.deb` from the console by hand instead:

```bash
nix-store --add-fixed sha256 falcon-sensor_8.x.x-xxxxx_amd64.deb
```

and either add it to `pkgs/sources.json` or pass it inline:

```nix
services.falcon-sensor.package = pkgs.falcon-sensor.override {
  name = "falcon-sensor_8.10.0-19402_amd64.deb";
  hash = "sha256-RVNTBhFgWCM2y2bT4POM6btnvXiOFReoL1LvODFvVs8=";
};
```


## Fetching on the host

By default the sensor comes from the pinned package and **no API credentials ever reach an
endpoint**. `apiRefresh` reverses that: each host authenticates to the Sensor Download API
itself, on a timer, and installs whatever its sensor update policy allows.

```nix
services.falcon-sensor.apiRefresh = {
  enable = true;
  clientIdFile     = "/run/secrets/falcon-api-client-id";
  clientSecretFile = "/run/secrets/falcon-api-client-secret";
  updatePolicy     = "platform_default";   # keeps the fleet on N-1/N-2
  interval         = "daily";
};
```

Credentials follow the same convention as everything else — runtime paths, delivered through
systemd credentials, never in a unit file or the journal. The VM test asserts that.

**Understand the trade-off before enabling this.** It buys sensor upgrades without a rebuild,
and it is the only way to track a sensor update policy automatically. It costs:

- **API credentials on every endpoint.** A client that can download sensors for the whole
  tenant now lives on each host. Scope it to *Sensor Download: read* and nothing else.
- **The installed sensor is no longer described by the system closure.** Two hosts on the same
  NixOS generation can be running different sensors. `nixos-rebuild` no longer tells you what
  is deployed; the console does.
- **Runtime ELF patching.** A sensor fetched at boot never passes through `autoPatchelfHook`,
  so `update-sensor --install-dir` rewrites each binary's interpreter and RPATH against the
  same library set the package uses. That set is baked into the updater at build time, so it
  cannot drift from the packaged sensor — but it is patching done on the host, not in a sandbox.

With `apiRefresh` on, `falcon-sensor-setup` stops populating the state directory — otherwise it
would overwrite a newer API-fetched sensor with the pinned one on every boot — and `package` is
used only for its metadata. `falconstore`, `falconstore.bak` and `falconctl.conf` are carried
across an in-place upgrade, so the host keeps its Agent ID.

The refresh is a no-op when the installed version already matches, and the timer carries a
one-hour `RandomizedDelaySec` so a fleet does not wake up and hit the API in lockstep.

## Secrets

`cidFile`, `provisioningTokenFile` and `maintenanceTokenFile` are **absolute paths to runtime
files** — typed as strings, never Nix paths, so they can never be copied into the
world-readable `/nix/store`. The module refuses any value under `/nix/store` at eval time.

Values are delivered to `falconctl` through systemd credentials (`LoadCredential`) and read from
`$CREDENTIALS_DIRECTORY` inside the unit's script, so they appear in no unit file, no
`nixos-rebuild` log, and no journal entry. The VM test asserts this.

Provide the files with whatever you already use. With **sops-nix**:

```nix
sops.secrets.falcon-provisioning-token = { };   # -> /run/secrets/falcon-provisioning-token

services.falcon-sensor.provisioningTokenFile =
  config.sops.secrets.falcon-provisioning-token.path;
```

With **agenix**:

```nix
age.secrets.falcon-provisioning-token.file = ./secrets/falcon-provisioning-token.age;

services.falcon-sensor.provisioningTokenFile =
  config.age.secrets.falcon-provisioning-token.path;
```

The updater's API credentials follow the same convention — `--client-id-file` /
`--client-secret-file` take a decrypted runtime path (or fall back to `$FALCON_CLIENT_ID` /
`$FALCON_CLIENT_SECRET`). They are never accepted as positional arguments, since argv is
readable through `/proc`.

Note that the **API credentials never appear in any NixOS module**. Pinning happens wherever you
run the updater; managed endpoints hold no Falcon API keys at all.

The `cid` option is plaintext and lands in the store. That is usually fine — the CID identifies
your tenant, it does not authenticate — but `cidFile` is there if yours is treated as sensitive.
`--record-cid` writes the CID into the pin; it is off by default because `pkgs/sources.json` is
committed.

### One honest gap

`falconctl` accepts the provisioning and maintenance tokens only on its own argv. The module
assembles the arguments inside the unit's script so the value never reaches the unit file, but
during the brief `falcon-sensor-configure` run the token is visible in `/proc` to root. There is
no file or stdin interface to use instead.

## Impermanence

Everything mutable lives under `services.falcon-sensor.statePath`
(default `/var/lib/falcon-sensor`): the device identity in `falconstore` — which carries the
Agent ID — the configuration `falconctl` writes, and the channel files the sensor downloads.
Persist that one directory:

```nix
environment.persistence."/persist".directories = [ "/var/lib/falcon-sensor" ];

# or, without hardcoding the path:
environment.persistence."/persist".directories =
  config.services.falcon-sensor.persistedPaths;
```

Without it the sensor loses its AID on every boot, re-registers as a brand-new host, and
re-downloads every channel file.

The module deliberately does **not** set `environment.persistence` itself. Impermanence asserts
on duplicate paths, so a module that adds a path you have also listed breaks evaluation.

Caveats worth knowing:

- Impermanence requires `neededForBoot = true` on the filesystem hosting `/persist`, and on any
  filesystem containing an ephemeral target. It fails evaluation otherwise.
- Persisted directories are real bind mounts ordered `Before=local-fs.target`, so they are in
  place long before `multi-user.target`. The module's units also declare `RequiresMountsFor`
  on `statePath`, so the dependency is explicit either way.
- **Do not clone a host with a populated `/var/lib/falcon-sensor`** — every clone reports as the
  same device. For golden images set `autoRemoveAid = true`, which clears the AID on each start.
- Nothing under `/opt` needs persisting. It is refreshed from the Nix store on every activation.

## How it works

`falcond` hard-codes `/opt/CrowdStrike` for both its binaries and its state, and a store symlink
there is not good enough: an EDR resolves its own and its peers' identities through
`/proc/<pid>/exe`, which would read back as a `/nix/store` path.

So `falcon-sensor-setup.service` copies the shipped files out of the store into
`${statePath}/opt` — guarded by a `.nix-generation` stamp, so only store-provided filenames are
refreshed on a version bump and the sensor's own state survives — then bind-mounts that onto
`/opt/CrowdStrike`. A bind mount, unlike a symlink, preserves the visible path. The mount is
guarded by `mountpoint -q`, so repeated `nixos-rebuild switch` runs do not stack mounts.

`preserveFiles` (default `[ "falconstore" "falconstore.bak" "falconctl.conf" ]`) names files that are never
overwritten from the store once they exist. `falconstore` holds the Agent ID, so if a sensor
release ships that name in its own `.deb`, refreshing it on a version bump would discard the
host's identity — destroying the very thing persisting `statePath` exists to protect. They are
still created on first start.

`falcon-sensor-configure.service` then applies settings with `falconctl -s -f`, and
`falcon-sensor.service` runs the daemon.

This is also why the module does not use `buildFHSEnv`: in current nixpkgs that is the
bubblewrap implementation, which puts the daemon in its own mount namespace — the opposite of
what a kernel-level EDR needs, and it makes `/proc/<pid>/exe` unstable.

## Reduced Functionality Mode

The sensor validates the running kernel against CrowdStrike's supported-kernel list and falls
back to **RFM** when it is not on that list — which is usually the case for NixOS kernels. In
RFM the sensor still reports heartbeats and asset inventory, but performs no detection or
prevention.

```bash
# is the sensor actually degraded?
/opt/CrowdStrike/falconctl -g --rfm-state --rfm-reason --version --aid

# would this kernel be supported?
falcon-kernel-check
```

`backend = "bpf"` is the default because the eBPF backend runs in user space and has far looser
kernel requirements than the `kernel` backend, which wants a module built against a supported
kernel. No packaging choice avoids RFM entirely; that is a decision on CrowdStrike's side.

`falconctl` writes to `/var/log/falconctl.log`, so check there as well as the journal when the
sensor misbehaves. On an impermanent host that log is lost at reboot unless `/var/log` is
persisted separately — that is normal and nothing the sensor depends on.


## The systemd unit, and prior art

Sensor **8.10.0-19402 does ship its own unit** at `lib/systemd/system/falcon-sensor.service`,
so `useVendorUnit = true` works and is the recommended setting — it removes all guesswork. The
real unit is:

```ini
[Unit]
DefaultDependencies=no
After=local-fs.target
RequiresMountsFor=/opt /var
Conflicts=shutdown.target
Before=shutdown.target

[Service]
ExecStartPre=/opt/CrowdStrike/falconctl -g --cid
ExecStart=/opt/CrowdStrike/falcond
Type=forking
PIDFile=/var/run/falcond.pid
Restart=no
TimeoutStopSec=60s
KillMode=control-group
KillSignal=SIGTERM
Delegate=yes
```

The module's own unit (`useVendorUnit = false`, the default) now matches this, with one
deliberate difference: `restart` defaults to `on-failure` rather than `no`, so a crashed
security agent comes back. Set `restart = "no"` to match the vendor exactly.

Worth noting against the community modules, all of which set `WorkingDirectory=/opt/CrowdStrike`:
**the vendor does not set it**, and `Delegate=yes` — which none of them set — is real and
matters, since the sensor manages its own cgroup subtree. `PIDFile` is `/var/run/falcond.pid`,
not `/run/falcond.pid`; the two resolve to the same file through the usual symlink, but the
`pidFile` option defaults to the vendor's spelling. If the service ever fails with `Can't open
PID file ... after start`, set `pidFile = null` and let systemd find the main process itself.

Two mistakes visible in the community modules that this one deliberately avoids:

- **Symlinking the store into `/opt/CrowdStrike`.** Everything in the `.deb` is installed
  read-only (`-r-xr-xr-x`), and the sensor writes into `Packages/`, `ASPM/results`, `ASPM/tmp`
  and `Falcon4IT/results` at runtime. Symlinks into the store make that impossible; this module
  copies and then applies a recursive `chmod u+w`.
- **`rm -rf /opt/CrowdStrike` in `ExecStartPre`.** That wipes the sensor's identity on every
  boot, and is the likely cause of the `Invalid file /opt/CrowdStrike/falconstore length: 0`
  reports. Here the refresh is stamp-guarded, with `preserveFiles` protecting identity files.

### Upgrades

The sensor ships version-stamped filenames behind unversioned symlinks — `falconctl19402`,
`falcon-aspm19402`, `KernelModuleArchive19402` and so on. A refresh that only replaced the names
present in the *new* package would strand the previous version's files forever, and they are
large: one stale generation is over 150 MB sitting in the directory an impermanent host
persists. The setup service therefore records a manifest of what it installed and removes
anything the next version no longer ships.

## Upstreaming to nixpkgs

The layout is deliberately the shape nixpkgs expects, so moving it upstream is a file move
rather than a rewrite:

| Here | In nixpkgs |
| --- | --- |
| `pkgs/falcon-sensor.nix` + `pkgs/sources.json` | `pkgs/by-name/fa/falcon-sensor/{package.nix,sources.json}` |
| `modules/falcon-sensor.nix` | `nixos/modules/services/security/falcon-sensor.nix` |
| `tests/module.nix` | `nixos/tests/falcon-sensor.nix`, wired up as `passthru.tests` |

Three decisions follow from that goal:

- **The pin is a package argument, not a module option.** `version` selects from a
  version-keyed `sources` table feeding `requireFile` — the same shape as nixpkgs'
  `cisco-packet-tracer_9`, which is behind an identical login wall. Essentially no NixOS module
  in the tree exposes a source hash as an option, and a module could not read a pin file anyway:
  upstream it lives in a different tree from the package.
- **`sources.json` sits beside the package**, not at the repo root, so it travels with
  `package.nix` into `pkgs/by-name/`. Keeping a JSON pin next to a package is an existing
  nixpkgs idiom (`1password-gui`, `acli`, `p3x-onenote`, and others).
- **The module resolves `pkgs.falcon-sensor` first**, falling back to `callPackage` only when
  the overlay is absent, so the `package` default collapses to a plain `mkPackageOption`
  upstream with no behaviour change.

`requireFile` packages are established in nixpkgs — around fifty of them — so an installer that
cannot be fetched during a build is not itself a blocker. What *is* different from most of them
is that there is no single canonical version: which sensor a tenant may install is set by that
tenant's sensor update policy, so the shipped pin is a starting point that any user is expected
to override. That is also why there is no `passthru.updateScript` — refreshing the pin needs
CrowdStrike API credentials and cannot run unattended.

## Packaging notes

The `.deb` is unpacked with `dpkg-deb -x` and patched with `autoPatchelfHook`.
`autoPatchelfIgnoreMissingDeps` is deliberately **not** set, so a missing library fails the
build instead of crashing at runtime. If a new sensor version pulls in a library the derivation
does not provide, the build will say so; find it with:

```bash
nix develop
readelf -d result/opt/CrowdStrike/falcond | grep NEEDED
```

and add it to `buildInputs` in `pkgs/falcon-sensor.nix`.

The binaries are not stripped (`dontStrip = true`) — the sensor is signed and self-checking. If
a future version turns out to reject `autoPatchelfHook`'s rewriting, the fallback is to set only
the interpreter and an explicit `--set-rpath` with `dontPatchELF = true`, the way nixpkgs'
`intune-portal` does.

## Development

```bash
nix flake check     # evaluates everything and runs the VM test
nix fmt
nix develop         # dpkg, patchelf, readelf, curl, jq, shellcheck
```

The VM test in `tests/module.nix` builds a synthetic `.deb` with stub binaries, since the real
installer cannot live in CI. It covers the bind mount, mount idempotency, state survival across
a package refresh, the `falconctl` argv, and that the provisioning token reaches `falconctl`
without leaking into units or the journal.

## Status

Verified end-to-end against a real tenant with sensor **8.10.0-19402**: API authentication with
us-1 → us-2 region autodiscover, CID lookup, installer selection, download, checksum
verification, store pin, and a clean package build with `autoPatchelfHook` finding every
library it needed. The module is covered by a 17-subtest NixOS VM test across three nodes —
pinned, vendor-unit, and `apiRefresh`.

What that leaves:

- **Not yet run on a real host.** Everything above is build-time and VM-level. Whether
  `autoPatchelfHook`'s rewriting upsets the sensor's own integrity checking can only be
  answered by starting `falcond` on real hardware. If it does, the fallback is to set only the
  interpreter and an explicit `--set-rpath`, with `dontPatchELF = true`.
- **`apiRefresh`'s HTTP conversation is untested in CI.** The VM test substitutes a stub with
  the same interface, so credential delivery, ordering, setup deferral and the stop/install/start
  sequence are all covered — but the API call itself is only proven by the live run above, which
  exercised the same code path in `--dry-run` and pinning modes rather than `--install-dir`.
- **Expect RFM.** See above; nothing about the packaging changes that.
- `buildInputs` is confirmed sufficient for 8.10. A future sensor may need more; the build will
  say so rather than failing at runtime.
