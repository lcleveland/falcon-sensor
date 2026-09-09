#!/usr/bin/env python3
"""Tray icon for the CrowdStrike Falcon sensor.

CrowdStrike ships no GUI for Linux, and falconctl is root-only, so this renders
what falcon-sensor-status published rather than asking the sensor anything itself.
It is deliberately read-only: nothing here can start, stop or reconfigure a
security agent from a desktop session.

The icon is a StatusNotifierItem, so it lands in whatever tray the session already
has -- Quickshell/DankMaterialShell, waybar, KDE, an AppIndicator-capable GNOME --
rather than being written against one shell's widget API.

`--print-state` resolves the state and exits without touching Gtk or the session
bus, which is what makes the state machine testable in a VM with no display.
"""

import argparse
import json
import os
import sys
import time

STATUS_FILE = "/run/falcon-sensor/status.json"

# Kept in a dict rather than inlined so the icon names have exactly one home; the
# package installs an SVG per entry.
ICONS = {
    "protected": "falcon-sensor-protected",
    "degraded": "falcon-sensor-degraded",
    "inactive": "falcon-sensor-inactive",
    "unknown": "falcon-sensor-unknown",
}

SUMMARIES = {
    "protected": "Falcon sensor: protected",
    "degraded": "Falcon sensor: degraded",
    "inactive": "Falcon sensor: not running",
    "unknown": "Falcon sensor: state unknown",
}

# A status file this much older than the interval it declares is treated as no
# answer at all: three missed refreshes means the publisher is not running, and a
# stale "protected" is worse than an honest "unknown".
STALE_INTERVALS = 3


def load_status(path):
    """The published status, or None if there is nothing usable to read."""
    try:
        with open(path, "r") as fh:
            status = json.load(fh)
    except (OSError, ValueError):
        return None
    return status if isinstance(status, dict) else None


def humanize_age(seconds):
    seconds = int(max(seconds, 0))
    if seconds < 90:
        return f"{seconds}s ago"
    if seconds < 5400:
        return f"{seconds // 60}m ago"
    return f"{seconds // 3600}h ago"


def resolve(status, now):
    """(state, summary, detail rows) for the status file's contents.

    The order of the checks is the point: a sensor whose unit is dead cannot be
    reporting anything, and RFM is only meaningful for a sensor that is up.
    """
    if status is None:
        return "unknown", SUMMARIES["unknown"], ["No status file -- is falcon-sensor-status.service running?"]

    sensor = status.get("sensor") or {}
    service = status.get("service") or {}
    identifiers = status.get("identifiers") or {}

    generated = status.get("generated_epoch")
    interval = status.get("interval_seconds") or 60
    age = None
    if isinstance(generated, (int, float)):
        age = now - generated

    rows = []
    if sensor.get("version"):
        rows.append(f"Sensor {sensor['version']}")
    if service.get("active_state"):
        sub = service.get("sub_state")
        rows.append(f"Unit: {service['active_state']}" + (f" ({sub})" if sub else ""))
    if sensor.get("backend"):
        rows.append(f"Backend: {sensor['backend']}")

    if age is None:
        state = "unknown"
        rows.append("Status file carries no timestamp")
    elif age > STALE_INTERVALS * interval:
        state = "unknown"
        rows.append(f"Status is stale -- last checked {humanize_age(age)}")
    elif service.get("active_state") != "active":
        # The unit's state is trustworthy even when falconctl is not, so a dead
        # sensor is reported as dead rather than as unknown.
        state = "inactive"
    elif not sensor.get("queryable", True):
        # Nothing below this was actually asked -- publishing it as "not
        # registered, not in RFM" would look like a sensor in perfect health.
        state = "unknown"
        rows.append("falconctl could not be queried -- is the publisher running as root?")
    elif not sensor.get("registered"):
        state = "degraded"
        rows.append("Not registered with the tenant -- no Agent ID yet")
    elif sensor.get("rfm"):
        state = "degraded"
        reason = sensor.get("rfm_reason") or "reason not reported"
        rows.append(f"Reduced Functionality Mode: {reason}")
        rows.append("Heartbeats and inventory only -- no detection or prevention")
    else:
        state = "protected"

    if identifiers.get("aid"):
        rows.append(f"AID: {identifiers['aid']}")
    if identifiers.get("cid"):
        rows.append(f"CID: {identifiers['cid']}")
    if age is not None and state != "unknown":
        rows.append(f"Checked {humanize_age(age)}")

    return state, SUMMARIES[state], rows


def run_tray(args):
    # Imported here, not at module scope: --print-state must work on a host with
    # no display and no session bus, which is how the VM test drives this.
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
    from gi.repository import Gio, GLib, Gtk  # noqa: E402

    indicator = AppIndicator.Indicator.new_with_path(
        "falcon-sensor",
        ICONS["unknown"],
        AppIndicator.IndicatorCategory.SYSTEM_SERVICES,
        args.icon_path,
    )
    indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)

    def refresh(*_):
        state, summary, rows = resolve(load_status(args.status_file), time.time())

        indicator.set_icon_full(ICONS[state], summary)
        # Hosts that single out items needing attention should single these out;
        # ATTENTION also swaps in the attention icon, so it gets the same name.
        if state == "protected":
            indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        else:
            indicator.set_attention_icon_full(ICONS[state], summary)
            indicator.set_status(AppIndicator.IndicatorStatus.ATTENTION)
        # The tray's tooltip, for hosts that show one.
        indicator.set_title(summary)

        # Rebuilt rather than mutated: the row list changes shape between states.
        menu = Gtk.Menu()
        header = Gtk.MenuItem(label=summary)
        header.set_sensitive(False)
        menu.append(header)
        if rows:
            menu.append(Gtk.SeparatorMenuItem())
        for row in rows:
            item = Gtk.MenuItem(label=row)
            item.set_sensitive(False)
            menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())
        # Re-reads the published file. Not an action on the sensor -- there is
        # deliberately nothing here that can touch it.
        reload_item = Gtk.MenuItem(label="Reload status")
        reload_item.connect("activate", refresh)
        menu.append(reload_item)
        menu.show_all()
        indicator.set_menu(menu)
        return True

    refresh()

    # The publisher writes by renaming over the file, so the interesting events
    # land on the directory, not on the file itself.
    watch_dir = os.path.dirname(args.status_file) or "."
    basename = os.path.basename(args.status_file)
    monitor = Gio.File.new_for_path(watch_dir).monitor_directory(Gio.FileMonitorFlags.NONE, None)

    def on_change(_monitor, changed, _other, _event):
        if changed is not None and changed.get_basename() == basename:
            refresh()

    monitor.connect("changed", on_change)

    # Backstop for the monitor, and the only thing that can notice the status
    # going stale -- staleness is the passage of time, not a file event.
    GLib.timeout_add_seconds(args.poll, refresh)

    Gtk.main()
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="falcon-sensor-tray",
        description="Show the Falcon sensor's state as a tray icon",
    )
    parser.add_argument(
        "--status-file",
        default=STATUS_FILE,
        help=f"the JSON falcon-sensor-status publishes (default {STATUS_FILE})",
    )
    parser.add_argument(
        "--icon-path",
        default=os.environ.get("FALCON_TRAY_ICON_PATH", ""),
        help="directory holding the tray icons; baked in by the package",
    )
    parser.add_argument(
        "--poll",
        type=int,
        default=30,
        help="seconds between re-checks, for staleness (default 30)",
    )
    parser.add_argument(
        "--print-state",
        action="store_true",
        help="print the resolved state and its detail lines, then exit",
    )
    args = parser.parse_args(argv)

    if args.print_state:
        state, summary, rows = resolve(load_status(args.status_file), time.time())
        print(state)
        print(summary)
        for row in rows:
            print(f"  {row}")
        return 0

    return run_tray(args)


if __name__ == "__main__":
    sys.exit(main())
