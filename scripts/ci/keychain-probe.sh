#!/usr/bin/env bash
# What the Keychain allows an ad-hoc signed, sandboxed, optimized build (like the shipped DMG).
# Builds the probe twice with different code (so a different ad-hoc signature, like an app
# update), writes items with the first and reads them with the second. Informational: it never
# fails the build. A read that hangs means macOS showed an access prompt.
set -euo pipefail
work="${RUNNER_TEMP:-$(mktemp -d)}/keychain-probe"
rm -rf "$work" && mkdir -p "$work"
here=$(cd "$(dirname "$0")" && pwd)
cat > "$work/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.praxstack.ledgeratlas.keychain-probe</string>
  <key>CFBundleName</key><string>keychain-probe</string>
</dict></plist>
PLIST
cat > "$work/probe.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.praxstack.ledgeratlas</string></array>
</dict></plist>
PLIST
for build in first second; do
  cp "$here/keychain-probe.swift" "$work/$build.swift"
  echo "let build = \"$build\"" >> "$work/$build.swift"
  xcrun swiftc -O "$work/$build.swift" -o "$work/$build" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$work/Info.plist"
  codesign -s - -f -i com.praxstack.ledgeratlas.keychain-probe \
    --entitlements "$work/probe.entitlements" "$work/$build"
done
{
  echo "| build | step | status |"
  echo "|---|---|---|"
} > "$work/result.md"
run() {
  set +e
  # perl alarm: macOS has no `timeout`. A prompt blocks the call, so 20 s means "prompted".
  perl -e 'alarm shift; exec @ARGV' 20 "$@" >> "$work/result.md" 2>> "$work/stderr.txt"
  local status=$?
  set -e
  [ "$status" -eq 0 ] || echo "| $2 | exited with $status (142 = timed out, likely a prompt) | |" >> "$work/result.md"
}
run "$work/first" write
run "$work/second" read
cat "$work/result.md"
[ -s "$work/stderr.txt" ] && { echo "stderr:"; cat "$work/stderr.txt"; }
codesign -d -r- "$work/first" 2>&1 | tail -1
codesign -d -r- "$work/second" 2>&1 | tail -1
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Keychain probe (ad-hoc, sandboxed, optimized)"; cat "$work/result.md"; } >> "$GITHUB_STEP_SUMMARY"
fi
