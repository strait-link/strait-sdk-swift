#!/usr/bin/env python3
"""Rename attachments exported by `xcresulttool export attachments` to their test names."""
import json, os, re, sys

d = sys.argv[1]
for test in json.load(open(os.path.join(d, "manifest.json"))):
    for a in test.get("attachments", []):
        nice = re.sub(r"_\d+_[0-9A-F-]{36}(\.\w+)$", r"\1", a["suggestedHumanReadableName"])
        src = os.path.join(d, a["exportedFileName"])
        if os.path.exists(src):
            os.rename(src, os.path.join(d, nice))
