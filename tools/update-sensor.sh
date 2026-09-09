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
update-sensor -- pin a Falcon sensor installer from the CrowdStrike API

Credentials (required; needs the "Sensor Download: read" API scope):
  --client-id-file PATH      absolute path to a file holding the API client id
  --client-secret-file PATH  absolute path to a file holding the API client secret
                             Falls back to $FALCON_CLIENT_ID / $FALCON_CLIENT_SECRET.
                             Never pass a secret as an argument -- argv is world
                             readable through /proc.

Selection:
  --cloud REGION        autodiscover (default) | us-1 | us-2 | us-3 | eu-1
                        | us-gov-1 | us-gov-2
  --sensor-version VER  pin an exact sensor version (e.g. 7.20.0-17306)
  --update-policy NAME  take the version from a sensor update policy
                        (e.g. platform_default). Needs the
                        "Sensor update policies: read" scope.
  --os NAME             FQL os filter (e.g. Debian, Ubuntu)
  --os-version VER      FQL os_version filter (e.g. 12/13)
  --os-regex RE         client-side os filter, default ^(Debian|Ubuntu)$
  --arch ARCH           x86_64 (default) or arm64
  --filter FQL          replace the whole generated FQL filter

Output:
  --lockfile PATH       default ./sensor.lock.json
  --record-cid          also write the CID into the lockfile (see README --
                        the lockfile is committed, so this is off by default)
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
lockfile="sensor.lock.json"
record_cid=0
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
    --lockfile)           lockfile="$2"; shift 2 ;;
    --record-cid)         record_cid=1; shift ;;
    --dry-run)            dry_run=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "update-sensor: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "update-sensor: $*" >&2; exit 1; }

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

  # Verified against a real us-2 tenant: probing the wrong region answers
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

echo "update-sensor: authenticated against $host (cloud: $cloud)" >&2

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
  echo "update-sensor: customer CID is $cid" >&2
  echo "update-sensor:   set services.falcon-sensor.cid = \"$cid\"; (or point cidFile at a secret)" >&2
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
  echo "update-sensor: policy '$update_policy' selects sensor version $sensor_version" >&2
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
echo "update-sensor: installer filter: $filter" >&2

inst="$tmp/installers.json"
api_get /sensors/combined/installers/v2 --get \
  --data-urlencode "filter=$filter" \
  --data-urlencode "limit=500" \
  -o "$inst" || die "installer query failed"
check_errors "$inst" "installer query"

# Drop the SIEM connector (it matches a plain linux filter but is not a sensor),
# keep .deb only, apply the client-side os regex, then take the highest version.
sel="$(jq -c --arg re "$os_regex" '
  [ .resources[]?
    | select(((.description // "") | test("Falcon SIEM Connector")) | not)
    | select((.name // "") | endswith(".deb"))
    | select((.os // "") | test($re))
  ]
  | sort_by((.version // "0") | [splits("[.\\-]")] | map(tonumber? // 0))
  | last // empty' < "$inst")"

[ -n "$sel" ] || die "no matching .deb installer. Try relaxing --os-regex, or inspect the raw list with --filter and jq."

name="$(jq -r '.name' <<<"$sel")"
version="$(jq -r '.version' <<<"$sel")"
sha256="$(jq -r '.sha256' <<<"$sel")"
sel_os="$(jq -r '.os // ""' <<<"$sel")"
sel_osver="$(jq -r '.os_version // ""' <<<"$sel")"

echo "update-sensor: selected $name (version $version, $sel_os $sel_osver)" >&2

if [ "$dry_run" -eq 1 ]; then
  echo "update-sensor: --dry-run, stopping before download" >&2
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
echo "update-sensor: verified sha256 $sha256" >&2

# --- pin ---------------------------------------------------------------------

# Flat sha256, which is exactly what requireFile resolves. The store path is
# reproducible, so any other machine either has it already or runs this once.
store_path="$(nix-store --add-fixed sha256 "$deb")"
echo "update-sensor: added to the store as $store_path" >&2

lock="$(jq -n \
  --arg name "$name" --arg version "$version" --arg sha256 "$sha256" \
  --arg os "$sel_os" --arg os_version "$sel_osver" \
  --arg arch "$arch" --arg cloud "$cloud" \
  --arg retrieved "$(date -u +%Y-%m-%d)" \
  '{name:$name, version:$version, sha256:$sha256, os:$os,
    os_version:$os_version, arch:$arch, cloud:$cloud, retrieved:$retrieved}')"

if [ "$record_cid" -eq 1 ] && [ -n "$cid" ]; then
  lock="$(jq --arg cid "$cid" '. + {cid:$cid}' <<<"$lock")"
fi

printf '%s\n' "$lock" > "$lockfile"
chmod 644 "$lockfile"

echo "update-sensor: wrote $lockfile" >&2
echo "update-sensor: commit it -- it holds no secrets, and it is what makes the build reproducible" >&2
