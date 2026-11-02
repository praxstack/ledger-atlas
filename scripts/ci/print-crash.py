#!/usr/bin/env python3
"""Prints the faulting thread of a macOS .ips crash report (used by CI on test crashes)."""

import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    handle.readline()  # first line is a JSON header
    report = json.load(handle)
images = report.get("usedImages", [])
print("exception:", report.get("exception"))
for thread in report.get("threads", []):
    if not thread.get("triggered"):
        continue
    for frame in thread.get("frames", [])[:60]:
        image = images[frame.get("imageIndex", 0)] if images else {}
        print(
            f"{image.get('name', '?')}  {frame.get('symbol', '?')}  +{frame.get('symbolLocation', '')}"
        )
