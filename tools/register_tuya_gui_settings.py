#!/usr/bin/env python3
"""Register GX-wide custom V6 GUI sensor layout in Victron localsettings.

Default mode prints what would be done. Use --install only on Cerbo with
system D-Bus access. Does not touch existing sensor/Node-RED services.
"""
import argparse
import json
import sys

PATH = "/Settings/Custom/Tuya/GuiSensorLayout"
DEFAULT = json.dumps({"order": ["240", "241", "242", "243"], "hidden": [], "names": {}}, separators=(",", ":"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Register setting through Venus OS D-Bus")
    args = parser.parse_args()
    if not args.install:
        print("DRY RUN: Would register", PATH, "default", DEFAULT)
        return 0
    try:
        import dbus
        bus = dbus.SystemBus()
        result = bus.call_blocking(
            "com.victronenergy.settings", "/", "com.victronenergy.Settings",
            "AddSettings", "aa{sv}", ([{
                "path": PATH, "default": DEFAULT, "min": 0, "max": 0, "silent": True
            }],), timeout=30.0)
        if not result or int(result[0]["error"]) != 0:
            print("ERROR: settings manager rejected request:", result, file=sys.stderr)
            return 1
        # AddSettings leaves existing values intact; no overwrite of user layout.
        print("Registered", PATH, "(existing value preserved if already present)")
        return 0
    except Exception as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
