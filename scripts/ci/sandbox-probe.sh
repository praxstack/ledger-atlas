#!/usr/bin/env bash
# Measures what the App Sandbox lets the ledger do next to a user-chosen file.
# The probe gets a grant for one file path and one folder, like the save/open panels give
# the shipped app, and prints a table. Informational: it does not fail the build.
set -euo pipefail
work="${RUNNER_TEMP:-$(mktemp -d)}/sandbox-probe"
rm -rf "$work" && mkdir -p "$work/chosen" "$work/folder"
granted="$work/chosen/ledger.sqlite"
xcrun swiftc -O "$(dirname "$0")/sandbox-probe.swift" -lsqlite3 -o "$work/probe"
cat > "$work/probe.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.files.absolute-path.read-write</key>
  <array><string>$granted</string><string>$work/folder/</string></array>
</dict></plist>
PLIST
codesign -s - -f -i com.praxstack.ledgeratlas.sandbox-probe \
  --entitlements "$work/probe.entitlements" "$work/probe"
"$work/probe" "$granted" "$work/folder" | tee "$work/result.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Sandbox file-access probe"; cat "$work/result.md"; } >> "$GITHUB_STEP_SUMMARY"
fi
