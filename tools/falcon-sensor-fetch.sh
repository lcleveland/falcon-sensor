# shellcheck shell=bash
#
# Pin a CrowdStrike Falcon sensor .deb from the Sensor Download API.
#
# Talks to the API, picks a suitable installer, downloads it, verifies the
# checksum the API declared, adds the blob to the Nix store, and writes
# sensor.lock.json. After that the package builds purely and offline -- no
# credentials and no network are ever needed at build time.
#
# API paths below were verified against CrowdStrike's generated `gofalcon`
# client; the selection flow mirrors CrowdStrike/falcon-installer's
# pkg/falcon/falcon.go.

usage() {
  cat <<'USAGE'
falcon-sensor-fetch -- download and install a Falcon sensor from the CrowdStrike API

Credentials (required; needs the "Sensor Download: read" API scope):
  --client-id-file PATH      absolute path to a file holding the API client id
  --client-secret-file PATH  absolute path to a file holding the API client secret
                             Falls back to $FALCON_CLIENT_ID / $FALCON_CLIENT_SECRET.
                             Never pass a secret as an argument -- argv is world
                             readable through /proc.

Selecting a sensor:
  --hash HASH           install exactly this sensor. Accepts an SRI hash
                        (sha256-...) or bare hex. This is the sha256 of the
                        installer, which is also the API's id for it, so it
                        both selects and verifies. Takes precedence over
                        everything below.
  --update-policy NAME  take the version from a sensor update policy
                        (e.g. platform_default). Needs the
                        "Sensor update policies: read" scope.
  --sensor-version VER  an exact sensor version (e.g. 8.10.0-19402)
  --cloud REGION        autodiscover (default) | us-1 | us-2 | us-3 | eu-1
                        | us-gov-1 | us-gov-2
  --os NAME             FQL os filter (e.g. Debian, Ubuntu)
  --os-version VER      FQL os_version filter (e.g. 12/13)
  --os-regex RE         client-side os filter, default ^(Debian|Ubuntu)$
  --arch ARCH           x86_64 (default) or arm64
  --filter FQL          replace the whole generated FQL filter

Modes:
  --list                print every matching sensor with its SRI hash, for
                        pasting into services.falcon-sensor.hash, then exit
  --preserve "A B C"    space-separated basenames carried across an in-place
                        upgrade, default "falconstore falconstore.bak falconctl.conf"
  --install-dir DIR     download, verify, unpack, patch the ELF headers for
                        this host and install into DIR, keeping the sensor's
                        identity files. A no-op when DIR already holds the
                        requested sensor.
  --dry-run             resolve and print the selection, download nothing
  -h, --help            this text
USAGE
}

client_id_file=""
client_secret_file=""
cloud="autodiscover"
sensor_version=""
update_policy=""
os_name=""
os_version=""
os_regex='^(Debian|Ubuntu)$'
arch="x86_64"
filter_override=""
target_hash=""
list_only=0
preserve="falconstore falconstore.bak falconctl.conf"
install_dir=""
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --client-id-file)     client_id_file="$2"; shift 2 ;;
    --client-secret-file) client_secret_file="$2"; shift 2 ;;
    --cloud)              cloud="$2"; shift 2 ;;
    --sensor-version)     sensor_version="$2"; shift 2 ;;
    --update-policy)      update_policy="$2"; shift 2 ;;
    --os)                 os_name="$2"; shift 2 ;;
    --os-version)         os_version="$2"; shift 2 ;;
    --os-regex)           os_regex="$2"; shift 2 ;;
    --arch)               arch="$2"; shift 2 ;;
    --filter)             filter_override="$2"; shift 2 ;;
    --hash)               target_hash="$2"; shift 2 ;;
    --list)               list_only=1; shift ;;
    --preserve)           preserve="$2"; shift 2 ;;
    --install-dir)        install_dir="$2"; shift 2 ;;
    --dry-run)            dry_run=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "falcon-sensor-fetch: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "falcon-sensor-fetch: $*" >&2; exit 1; }

# Idempotence, checked before anything touches the network. With an explicit
# --hash the target is known without asking the API, so a host that already has
# that sensor does no I/O at all -- which is what makes this safe to run on
# every boot. Without --hash the target depends on the update policy, so the
# API has to be consulted and the check happens after selection instead.
if [ -n "$install_dir" ] && [ -n "$target_hash" ]; then
  case "$target_hash" in
    sha256-*) want="$(nix hash convert --hash-algo sha256 --to base16 "$target_hash")" ;;
    *)        want="$target_hash" ;;
  esac
  if [ "$(cat "$install_dir/.installed-hash" 2>/dev/null || true)" = "$want" ]; then
    echo "falcon-sensor-fetch: $want already installed in $install_dir, nothing to do" >&2
    exit 0
  fi
fi

# --- credentials -------------------------------------------------------------
#
# Read once into shell variables. They are written only into mode-0600 temp
# files below and never appear on any command line.

read_secret() { # <file> <env-fallback-name> <label>
  local f="$1" envname="$2" label="$3" val=""
  if [ -n "$f" ]; then
    [ -r "$f" ] || die "cannot read $label from '$f'"
    # Strip a trailing newline; editors and secret managers add one.
    val="$(tr -d '\n' < "$f")"
  else
    val="${!envname-}"
  fi
  [ -n "$val" ] || die "no $label -- pass the matching --*-file or set \$$envname"
  printf '%s' "$val"
}

client_id="$(read_secret "$client_id_file" FALCON_CLIENT_ID "API client id")"
client_secret="$(read_secret "$client_secret_file" FALCON_CLIENT_SECRET "API client secret")"

# --- scratch -----------------------------------------------------------------

umask 077
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# --- cloud regions -----------------------------------------------------------
# From gofalcon/falcon/cloud.go.

cloud_host() {
  case "${1//-/}" in
    us1)    echo "api.crowdstrike.com" ;;
    us2)    echo "api.us-2.crowdstrike.com" ;;
    us3)    echo "api.us-3.crowdstrike.com" ;;
    eu1)    echo "api.eu-1.crowdstrike.com" ;;
    usgov1|gov1) echo "api.laggar.gcw.crowdstrike.com" ;;
    usgov2|gov2) echo "api.us-gov-2.crowdstrike.mil" ;;
    *) die "unrecognised cloud region: $1" ;;
  esac
}

# --- auth --------------------------------------------------------------------

urlenc() { printf '%s' "$1" | jq -sRr @uri; }

token=""
region=""

# POST /oauth2/token. The body goes through a 0600 temp file rather than
# --data-urlencode so the credentials stay off curl's argv.
#
# Returns 0 with $token set, non-zero otherwise, and always leaves $region set
# to whatever X-Cs-Region came back. This is deliberately never fatal:
# autodiscover has to inspect $region after a probe that did not yield a token.
authenticate() { # <host> -> sets $token and $region
  local host="$1" body="$tmp/body" hdrs="$tmp/hdrs" resp="$tmp/token.json" rc=0
  printf 'client_id=%s&client_secret=%s' \
    "$(urlenc "$client_id")" "$(urlenc "$client_secret")" > "$body"

  curl --silent --show-error --fail-with-body \
       --dump-header "$hdrs" \
       -H 'Content-Type: application/x-www-form-urlencoded' \
       --data "@$body" \
       -o "$resp" \
       "https://${host}/oauth2/token" || rc=$?
  rm -f "$body"

  region="$(sed -n 's/^[Xx]-[Cc][Ss]-[Rr]egion:[[:space:]]*//p' "$hdrs" | tr -d '\r' | head -n1)"
  [ "$rc" -eq 0 ] || return "$rc"

  # Verified against a real tenant: probing the wrong region answers
  # "HTTP/1.1 308 Permanent Redirect" with X-Cs-Region naming the right cloud
  # and an empty body -- not the 403 the vendor SDK's autodiscover implies.
  # curl treats 3xx as success, so a missing token here is normal and must not
  # be fatal; deliberately not following the redirect, because curl drops the
  # Authorization header across hosts and every later call would need the right
  # host anyway.
  token="$(jq -r '.access_token // empty' < "$resp" 2>/dev/null || true)"
  rm -f "$resp"
  [ -n "$token" ] || return 1
}

if [ "$cloud" = "autodiscover" ]; then
  # Probe us-1 and let X-Cs-Region point us at the real cloud.
  host="$(cloud_host us-1)"
  if authenticate "$host"; then
    cloud="${region:-us-1}"
  else
    [ -n "$region" ] || die "authentication failed and no X-Cs-Region header came back -- check the client id/secret, and whether IP allowlisting in the Falcon console covers this host"
    discovered="$(cloud_host "$region")"
    if [ "$discovered" = "$host" ]; then
      die "authentication failed against $host (region $region) -- check the client id/secret, and whether IP allowlisting in the Falcon console covers this host"
    fi
    host="$discovered"
    authenticate "$host" \
      || die "region autodiscover pointed at $region but authentication failed against $host -- check the client id/secret and any IP allowlisting"
    cloud="$region"
  fi
else
  host="$(cloud_host "$cloud")"
  authenticate "$host" \
    || die "authentication failed against $host -- check the client id/secret, and whether IP allowlisting in the Falcon console covers this host"
fi

echo "falcon-sensor-fetch: authenticated against $host (cloud: $cloud)" >&2

# Bearer token via a curl config file, so it stays off argv too.
auth_cfg="$tmp/auth.conf"
printf 'header = "Authorization: Bearer %s"\n' "$token" > "$auth_cfg"

api_get() { # <path> [curl args...]
  local path="$1"; shift
  curl --silent --show-error --fail-with-body -K "$auth_cfg" "$@" "https://${host}${path}"
}

check_errors() { # <json-file> <what>
  local n
  n="$(jq -r '(.errors // []) | length' < "$1")"
  if [ "$n" -gt 0 ]; then
    die "$2: $(jq -r '[.errors[] | "\(.code) \(.message)"] | join("; ")' < "$1")"
  fi
}

# --- CID ---------------------------------------------------------------------

ccid_json="$tmp/ccid.json"
cid=""
if api_get /sensors/queries/installers/ccid/v1 -o "$ccid_json"; then
  check_errors "$ccid_json" "CCID lookup"
  cid="$(jq -r '.resources[0] // empty' < "$ccid_json")"
fi
if [ -n "$cid" ]; then
  echo "falcon-sensor-fetch: customer CID is $cid" >&2
  echo "falcon-sensor-fetch:   set services.falcon-sensor.cid = \"$cid\"; (or point cidFile at a secret)" >&2
fi

# --- version selection -------------------------------------------------------

if [ -n "$update_policy" ] && [ -n "$sensor_version" ]; then
  die "--update-policy and --sensor-version are mutually exclusive"
fi

if [ -n "$update_policy" ]; then
  pol="$tmp/policy.json"
  api_get /policy/combined/sensor-update/v2 --get \
    --data-urlencode "filter=platform_name:\"Linux\"+name.raw:\"${update_policy}\"" \
    -o "$pol" || die "sensor update policy lookup failed -- the client may lack the 'Sensor update policies: read' scope"
  check_errors "$pol" "sensor update policy lookup"
  raw_version="$(jq -r '
    [ .resources[]? | select(.enabled == true and .settings.stage == "prod")
      | .settings.sensor_version // empty ] | last // empty' < "$pol")"
  [ -n "$raw_version" ] || die "no enabled prod sensor update policy named '$update_policy'"
  # The installer FQL rejects decorated versions like "7.20.0 (LTS)".
  sensor_version="$(printf '%s' "$raw_version" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || printf '%s' "$raw_version")"
  echo "falcon-sensor-fetch: policy '$update_policy' selects sensor version $sensor_version" >&2
fi

# --- installer query ---------------------------------------------------------

if [ -n "$filter_override" ]; then
  filter="$filter_override"
else
  filter="platform:\"linux\"+architectures:\"${arch}\""
  # NB: a bare `[ -n x ] && ...` would abort the script under `set -e` whenever
  # the test is false, since the test is the statement's own exit status.
  if [ -n "$os_name" ]; then        filter="${filter}+os:\"${os_name}\""; fi
  if [ -n "$os_version" ]; then     filter="${filter}+os_version:\"${os_version}\""; fi
  if [ -n "$sensor_version" ]; then filter="${filter}+version:\"${sensor_version}\""; fi
fi
echo "falcon-sensor-fetch: installer filter: $filter" >&2

inst="$tmp/installers.json"
api_get /sensors/combined/installers/v2 --get \
  --data-urlencode "filter=$filter" \
  --data-urlencode "limit=500" \
  -o "$inst" || die "installer query failed"
check_errors "$inst" "installer query"

# The candidate list, least to most recent: drop the SIEM connector (it matches
# a plain linux filter but is not a sensor), keep .deb only, apply the
# client-side os regex.
candidates="$(jq -c --arg re "$os_regex" '
  [ .resources[]?
    | select(((.description // "") | test("Falcon SIEM Connector")) | not)
    | select((.name // "") | endswith(".deb"))
    | select((.os // "") | test($re))
  ]
  | sort_by((.version // "0") | [splits("[.\\-]")] | map(tonumber? // 0))' < "$inst")"

if [ "$list_only" -eq 1 ]; then
  # Newest first, since that is what a human is usually reaching for.
  jq -r 'reverse[] | "\(.version)\t\(.os) \(.os_version)\t\(.sha256)\t\(.name)"' <<<"$candidates" \
  | while IFS=$'\t' read -r v osname sha nm; do
      printf '%s  %-28s %s\n    hash = "%s";\n' \
        "$v" "$osname" "$nm" "$(nix hash convert --hash-algo sha256 --to sri "$sha")"
    done
  exit 0
fi

if [ -n "$target_hash" ]; then
  # An SRI hash is what the module option carries; the API indexes installers by
  # the bare hex of the same sha256, so accept either and normalise to hex.
  case "$target_hash" in
    sha256-*) hex="$(nix hash convert --hash-algo sha256 --to base16 "$target_hash")" ;;
    *)        hex="$target_hash" ;;
  esac
  sel="$(jq -c --arg h "$hex" 'map(select(.sha256 == $h)) | last // empty' <<<"$candidates")"
  if [ -z "$sel" ]; then
    # Not in the filtered list, but the hash is the API's own id -- so the
    # download will still work. Trust it rather than refusing.
    echo "falcon-sensor-fetch: $hex is not in the current installer list; downloading by hash anyway" >&2
    sel="$(jq -nc --arg h "$hex" '{name:"falcon-sensor.deb", version:"unknown", sha256:$h, os:"", os_version:""}')"
  fi
else
  sel="$(jq -c 'last // empty' <<<"$candidates")"
fi

[ -n "$sel" ] || die "no matching .deb installer. Try relaxing --os-regex, or inspect the raw list with --list."

name="$(jq -r '.name' <<<"$sel")"
version="$(jq -r '.version' <<<"$sel")"
sha256="$(jq -r '.sha256' <<<"$sel")"
sel_os="$(jq -r '.os // ""' <<<"$sel")"
sel_osver="$(jq -r '.os_version // ""' <<<"$sel")"

echo "falcon-sensor-fetch: selected $name (version $version, $sel_os $sel_osver)" >&2

if [ "$dry_run" -eq 1 ]; then
  echo "falcon-sensor-fetch: --dry-run, stopping before download" >&2
  jq -n --arg n "$name" --arg v "$version" --arg s "$sha256" \
        --arg o "$sel_os" --arg ov "$sel_osver" \
        '{name:$n, version:$v, sha256:$s, os:$o, os_version:$ov}'
  exit 0
fi

# --- download and verify -----------------------------------------------------

deb="$tmp/$name"
api_get "/sensors/entities/download-installer/v2?id=${sha256}" -o "$deb" \
  || die "download failed for $name"

actual="$(sha256sum "$deb" | cut -d' ' -f1)"
[ "$actual" = "$sha256" ] \
  || die "checksum mismatch for $name: API declared $sha256, downloaded file is $actual"
echo "falcon-sensor-fetch: verified sha256 $sha256" >&2

# --- install mode ------------------------------------------------------------
#
# Unpack straight into a host's state directory instead of pinning. Used by
# falcon-sensor-fetch.service; there is no Nix store involvement, so the
# binaries never pass through autoPatchelfHook and have to be patched here.

if [ -n "$install_dir" ]; then
  marker="$install_dir/.installed-hash"

  if [ "$(cat "$marker" 2>/dev/null || true)" = "$sha256" ]; then
    echo "falcon-sensor-fetch: $version ($sha256) already installed in $install_dir" >&2
    exit 0
  fi

  : "${FALCON_INTERPRETER:?set by the falcon-sensor-fetch package}"
  : "${FALCON_RPATH:?set by the falcon-sensor-fetch package}"

  staging="$tmp/root"
  mkdir -p "$staging"
  dpkg-deb -x "$deb" "$staging"

  [ -d "$staging/opt/CrowdStrike" ] \
    || die "the .deb did not contain opt/CrowdStrike -- layout changed?"

  # Everything ships read-only, and the sensor writes into its own
  # subdirectories at runtime.
  chmod -R u+w "$staging/opt/CrowdStrike"

  # NixOS has no /lib64/ld-linux-x86-64.so.2 and no FHS library directories, so
  # every ELF needs its interpreter and RPATH rewritten. Shared objects get an
  # RPATH but no interpreter; patchelf reports the rest as not-an-ELF and those
  # are skipped.
  patched=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if ! patchelf --print-rpath "$f" >/dev/null 2>&1; then
      continue
    fi
    if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
      patchelf --set-interpreter "$FALCON_INTERPRETER" "$f" 2>/dev/null || true
    fi
    patchelf --set-rpath "$FALCON_RPATH:$install_dir" "$f" 2>/dev/null || true
    patched=$((patched + 1))
  done < <(find "$staging/opt/CrowdStrike" -type f)
  echo "falcon-sensor-fetch: patched $patched ELF objects for this host" >&2

  # Preserve the sensor's identity across an in-place upgrade. Same names the
  # module's preserveFiles protects; falconstore carries the AID.
  install -d -m 0755 "$install_dir"
  for keep in $preserve; do
    if [ -e "$install_dir/$keep" ]; then
      cp -a "$install_dir/$keep" "$staging/opt/CrowdStrike/$keep"
    fi
  done

  # Swap in. Not atomic -- the directory is a bind-mount source, so it cannot be
  # replaced by rename -- but the sensor is stopped by the caller first.
  find "$install_dir" -mindepth 1 -maxdepth 1 \
    ! -name '.installed-hash' -exec rm -rf {} +
  cp -a "$staging/opt/CrowdStrike/." "$install_dir/"

  printf %s "$sha256" > "$marker"
  echo "falcon-sensor-fetch: installed $version ($sha256) into $install_dir" >&2
  exit 0
fi

