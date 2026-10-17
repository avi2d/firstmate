#!/usr/bin/env python3
# Read simctl JSON devices from stdin, print one tab-separated line per device.
import json, sys
info = json.load(sys.stdin)
for runtime, devs in info.get("devices", {}).items():
    short = runtime.rsplit(".", 1)[-1].replace("-", " ")
    for d in devs:
        avail = "yes" if d.get("isAvailable") else "no"
        print("\t".join([d.get("udid", ""), d.get("state", ""), avail,
            d.get("name", ""), short, str(d.get("lastUsedAt", ""))]))
