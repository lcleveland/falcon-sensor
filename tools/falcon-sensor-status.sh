# shellcheck shell=bash
#
# Publish the Falcon sensor's state as JSON, for anything that wants to show it.
#
# falconctl is root-only (mode 0500, owned by root), so an unprivileged session --
# a tray icon, a status bar -- cannot ask the sensor anything at all. This runs as
# root from a timer and leaves the answer in a world-readable file instead.
#
# Nothing secret goes in that file. The CID and the AID are published only under
# --identifiers, because the file is readable by every local user and this module
# already treats the CID as something a site may consider sensitive (see the
# cidFile option).

usage() {
  cat <<'USAGE'
falcon-sensor-status -- publish the Falcon sensor's state as JSON

  --install-dir DIR   where the sensor lives, default /opt/CrowdStrike
  --output PATH       write the JSON here, atomically and mode 0644.
                      Default is stdout.
  --interval SECONDS  how often this is expected to run, default 60. Recorded in
                      the file so a reader can tell a stale answer from a current
                      one without knowing the timer's schedule.
  --identifiers       also publish the AID and the CID. Off by default: the file
                      is world-readable.
  -h, --help          this text

Must run as root -- falconctl refuses everyone else, and every sensor field comes
back null.
USAGE
}

install_dir="/opt/CrowdStrike"
output=""
interval=60
identifiers=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install-dir) install_dir="$2"; shift 2 ;;
    --output)      output="$2"; shift 2 ;;
    --interval)    interval="$2"; shift 2 ;;
    --identifiers) identifiers=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "falcon-sensor-status: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "falcon-sensor-status: $*" >&2; exit 1; }

case "$interval" in
  *[!0-9]*|"") die "--interval takes whole seconds, got '$interval'" ;;
esac

falconctl="$install_dir/falconctl"

if [ "$(id -u)" -ne 0 ]; then
  echo "falcon-sensor-status: not running as root -- falconctl will refuse, and every sensor field will be null" >&2
fi

# Ask falconctl for one setting.
#
# `falconctl -g` has no single output format. Observed on 8.10:
#
#   version = 7.20.0-17306.
#   rfm-state=false.
#   aid="0123456789abcdef0123456789abcdef".
#   cid is not set.
#
# -- so a value is dug out of whatever came back rather than parsed positionally,
# and each flag is queried on its own: one unset setting must not take the rest of
# the answer down with it, and asking one at a time keeps the output attributable
# to the flag that produced it.
probe() { # <key> -> the value, or nothing when unset/unavailable
  local key="$1" out line
  out="$("$falconctl" -g "--$key" 2>/dev/null)" || return 0
  # "... is not set." and its friends carry no `key=`, which is what marks a
  # setting as absent rather than empty.
  line="$(printf '%s\n' "$out" | grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" || true)"
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/\.$//' -e 's/^"//' -e 's/"$//'
}

version=""
rfm_state=""
rfm_reason=""
backend=""
aid=""
cid=""

# Whether falconctl answered at all, which is a different thing from every
# setting being unset -- an unprivileged run gets "Permission denied" for all of
# them, and a sensor that has not been fetched yet has no falconctl to run. Both
# must publish "unknown" rather than a plausible-looking set of falses that a
# display would render as a real answer.
queryable=false
if [ -x "$falconctl" ] && "$falconctl" -g --version >/dev/null 2>&1; then
  queryable=true

  version="$(probe version)"
  rfm_state="$(probe rfm-state)"
  rfm_reason="$(probe rfm-reason)"
  backend="$(probe backend)"
  aid="$(probe aid)"
  cid="$(probe cid)"
fi

# The unit's own state, which is the difference between "the sensor says it is
# fine" and "the sensor is running at all".
active_state="$(systemctl show falcon-sensor.service --property=ActiveState --value 2>/dev/null || true)"
sub_state="$(systemctl show falcon-sensor.service --property=SubState --value 2>/dev/null || true)"

# Registration is reported without publishing the identifier it is derived from:
# an AID exists once the sensor has registered with the tenant. Null, not false,
# when falconctl could not be asked.
registered=null
if [ "$queryable" = true ]; then
  registered=false
  [ -z "$aid" ] || registered=true
fi

json="$(
  jq -n \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson epoch "$(date +%s)" \
    --argjson interval "$interval" \
    --arg active "$active_state" \
    --arg sub "$sub_state" \
    --arg version "$version" \
    --arg rfm "$rfm_state" \
    --arg rfm_reason "$rfm_reason" \
    --arg backend "$backend" \
    --argjson registered "$registered" \
    --argjson queryable "$queryable" \
    --arg aid "$aid" \
    --arg cid "$cid" \
    --argjson identifiers "$identifiers" '
      def blank: if . == "" then null else . end;
      {
        generated: $generated,
        generated_epoch: $epoch,
        interval_seconds: $interval,
        service: {
          active_state: ($active | blank),
          sub_state: ($sub | blank),
        },
        sensor: {
          # False means every field below is "not asked", not "not set".
          queryable: $queryable,
          version: ($version | blank),
          # Tri-state on purpose: false is "not in RFM", null is "could not ask".
          rfm: (if $rfm == "true" then true elif $rfm == "false" then false else null end),
          # The sensor says "None" when it has no reason; that is not a reason.
          rfm_reason: ($rfm_reason | blank | if (. // "" | ascii_downcase) == "none" then null else . end),
          registered: $registered,
          backend: ($backend | blank),
        },
      }
      + (if $identifiers == 1 then
           { identifiers: { aid: ($aid | blank), cid: ($cid | blank) } }
         else
           { }
         end)
    '
)" || die "could not build the status JSON"

if [ -z "$output" ]; then
  printf '%s\n' "$json"
  exit 0
fi

# Atomically, so a reader never sees half an object: write beside the target (same
# filesystem, so the rename is atomic) and move it over.
dir="$(dirname "$output")"
install -d -m 0755 "$dir"
tmp="$(mktemp "$output.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$json" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$output"
trap - EXIT
