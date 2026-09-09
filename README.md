# falcon-sensor

The CrowdStrike Falcon sensor for Linux, packaged as a NixOS module.

Two things make this awkward on NixOS, and this flake handles both:

- **The installer is behind an authenticated API.** It cannot be `fetchurl`'d. Each host
  downloads it itself, using an API client id and secret you supply as files.
- **The sensor hard-codes `/opt/CrowdStrike` and writes its identity there.** On a tmpfs root
  that is lost every boot. The module relocates all mutable state to a single `/var/lib`
  directory and bind-mounts it into place, so an impermanent host has exactly one path to
  persist.

> **Proprietary and non-redistributable.** Nothing about the sensor is committed here; each
> host fetches its own copy from your tenant.

## Usage

Create an API client in the Falcon console (**Support and resources → Resources and tools → API
clients and keys → Create API client**) with the **Sensor Download: read** scope and nothing
else. Put the id and secret in two files with sops-nix or agenix, then:

```nix
{
  inputs.falcon-sensor.url = "github:lcleveland/falcon-sensor";

  # in your host configuration
  imports = [ inputs.falcon-sensor.nixosModules.default ];

  services.falcon-sensor = {
    enable = true;

    api.clientIdFile     = "/run/secrets/falcon-api-client-id";
    api.clientSecretFile = "/run/secrets/falcon-api-client-secret";

    hash = "sha256-RVNTBhFgWCM2y2bT4POM6btnvXiOFReoL1LvODFvVs8="; # bump to upgrade
    cid  = "0123456789ABCDEF0123456789ABCDEF-01";
  };
}
```

That is the whole setup: two files, two paths, a hash and a CID.

## Choosing the hash

`hash` is the SHA-256 of the sensor `.deb`. CrowdStrike's download endpoint is keyed by that
same value (`?id=<sha256>`), so it both selects the installer and verifies it — there is
nothing else to pin.

List what your tenant can install, each with the line to paste:

```bash
nix run github:lcleveland/falcon-sensor#find-sensor -- \
  --client-id-file     /run/secrets/falcon-api-client-id \
  --client-secret-file /run/secrets/falcon-api-client-secret
```

```
8.10.19402  Ubuntu 16/18/20/22/24        falcon-sensor_8.10.0-19402_amd64.deb
    hash = "sha256-RVNTBhFgWCM2y2bT4POM6btnvXiOFReoL1LvODFvVs8=";
```

It also prints your CID. Upgrading is bumping `hash` and rebuilding.

**Leaving `hash` unset works but is not recommended.** The host then installs whatever
`api.updatePolicy` resolves to, or the newest available. That tracks your sensor update policy
without any action, but two hosts rebuilt on different days can land on different sensors, and
every boot has to ask the API which one to use. The module warns when it is unset.

With `hash` set, a host that already has that sensor does **no network I/O at all** at boot —
the check happens before authentication.

## What this costs

Worth being explicit, because the alternative designs trade differently:

- **API credentials live on every endpoint.** That is the price of "the user only creates two
  files". Scope the client to *Sensor Download: read* and nothing else, so a stolen credential
  can download installers and do nothing more.
- **The sensor is not in the system closure.** `nixos-rebuild` does not tell you which sensor is
  deployed — but with `hash` set, your configuration does.
- **No offline or air-gapped install**, and no sharing the sensor through a binary cache.
- **The binaries are patched for the host at install time** rather than by `autoPatchelfHook` in
  a build sandbox. The interpreter and library paths are baked into the fetch tool at build
  time, so they cannot drift from what the tool was built against.
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

`api.clientIdFile` and `api.clientSecretFile` follow the same convention, and are delivered to
the fetch tool the same way — through systemd credentials, read from `$CREDENTIALS_DIRECTORY`,
never as arguments, since argv is readable through `/proc`.

The `cid` option is plaintext and lands in the store. That is usually fine — the CID identifies
your tenant, it does not authenticate — but `cidFile` is there if yours is treated as sensitive.
`find-sensor` prints your CID alongside the available sensors, so you rarely need to look it up
in the console.

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
- Nothing under `/opt` needs persisting; it is reconstructed on every boot.

## How it works

`falcond` hard-codes `/opt/CrowdStrike` for both its binaries and its state, and a symlink there
is not good enough. An EDR resolves its own and its peers' identities through `/proc/<pid>/exe`;
the `.deb` installs everything read-only (`-r-xr-xr-x`) while the sensor writes into `Packages/`,
`ASPM/results`, `ASPM/tmp` and `Falcon4IT/results` at runtime. The files have to be real,
writable files at the hard-coded path.

So `falcon-sensor-fetch.service` installs into `${statePath}/opt` and bind-mounts that onto
`/opt/CrowdStrike`. A bind mount, unlike a symlink, preserves the visible path. The mount is
guarded by `mountpoint -q`, so repeated `nixos-rebuild switch` runs do not stack mounts, and the
install is guarded by `.installed-hash`, so a host that already has the pinned sensor does
nothing at all.

`preserveFiles` (default `[ "falconstore" "falconstore.bak" "falconctl.conf" ]`) names files
carried across an upgrade rather than replaced. `falconstore` holds the Agent ID; replacing it on
a version bump would discard the host's identity and force a re-registration — destroying the
very thing persisting `statePath` exists to protect.

The sensor ships version-stamped filenames behind unversioned symlinks (`falconctl19402`,
`falcon-aspm19402`, `KernelModuleArchive19402`). An upgrade replaces the directory wholesale
rather than merging, so the previous version's files — over 150 MB of them — are not stranded in
the directory an impermanent host persists.

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

Sensor 8.10.0-19402 ships its own unit, which this module reproduces rather than guesses at:

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

The module matches this with one deliberate difference: `restart` defaults to `on-failure`
rather than `no`, so a crashed security agent comes back. Set `restart = "no"` to match exactly.

Worth noting against the community NixOS modules, all of which set
`WorkingDirectory=/opt/CrowdStrike`: **the vendor does not set it**, and `Delegate=yes` — which
none of them set — is real and matters, since the sensor manages its own cgroup subtree.
`pidFile` defaults to the vendor's `/var/run/falcond.pid`; set it to `null` if the service ever
fails with `Can't open PID file ... after start`.

Two mistakes visible in the community modules that this one avoids:

- **Symlinking the store into `/opt/CrowdStrike`.** Everything in the `.deb` is read-only, and
  the sensor writes into its own subdirectories at runtime. Symlinks into the store make that
  impossible.
- **`rm -rf /opt/CrowdStrike` in `ExecStartPre`.** That wipes the sensor's identity on every
  boot, and is the likely cause of the `Invalid file /opt/CrowdStrike/falconstore length: 0`
  reports. Here the install is hash-guarded, with `preserveFiles` protecting identity files.

## Packaging notes

The sensor is unpacked with `dpkg-deb -x` and patched for the host: `falcon-sensor-fetch`
rewrites each ELF object's interpreter and RPATH, because a sensor fetched at runtime never
passes through `autoPatchelfHook`. The library set — `stdenv.cc.cc.lib`, `openssl`, `libnl`,
`zlib`, `elfutils`, `libbpf` — is baked into the tool at build time via `runtimeEnv`, so it
cannot drift from what the tool was built against. It is confirmed sufficient for 8.10.

If a future sensor needs a library that is not there, `falcond` will fail to start with a
missing-shared-object error. Add it to `pkgs/falcon-sensor-fetch.nix` and check with:

```bash
nix develop
readelf -d /opt/CrowdStrike/falcond | grep NEEDED
```

The binaries are never stripped — the sensor is signed and self-checking.

## Development

```bash
nix flake check     # evaluates everything and runs the VM test
nix fmt
nix develop         # dpkg, patchelf, readelf, curl, jq, shellcheck
```

The VM test in `tests/module.nix` substitutes a stub for `falcon-sensor-fetch` with the same
interface, since the API is unreachable from a test VM. Two nodes — hash-pinned and
policy-tracking — cover the bind mount, mount idempotency, that a pinned host does not re-fetch
a sensor it already has, that bumping the hash upgrades while `preserveFiles` keeps the Agent ID
and the old version's files are not stranded, the `falconctl` argv, and that no credential
reaches a unit file or the journal.

## Status

The API flow was verified end-to-end against a real tenant with sensor **8.10.0-19402**:
authentication with us-1 → us-2 region autodiscover, CID lookup, installer selection, download,
and checksum verification. The module is covered by a 9-subtest NixOS VM test.

What that leaves:

- **Not yet run on a real host.** Everything above is either API-level or VM-level. Whether the
  runtime ELF patching upsets the sensor's own integrity checking can only be answered by
  starting `falcond` on real hardware.
- **The `--install-dir` path is not exercised against the real API.** The live run covered
  authentication, selection and download; the unpack-and-patch half is covered only by the VM
  test's stub.
- **Expect RFM.** See above; nothing about the packaging changes that.
