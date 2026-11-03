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
# A throwaway self-signed code-signing identity, to test whether a stable certificate (unlike
# ad-hoc) keeps Keychain access across builds. It lives in a temporary keychain only.
kc="$work/sign.keychain-db"
setup_cert() {
security create-keychain -p probe "$kc"
security set-keychain-settings "$kc"
security unlock-keychain -p probe "$kc"
cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Ledger Atlas Probe Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -passout pass:probe \
  -out "$work/id.p12" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -passout pass:probe \
    -out "$work/id.p12"
security import "$work/id.p12" -k "$kc" -P probe -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k probe "$kc" >/dev/null
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')
openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :
}
cert_hash=$(setup_cert 2>"$work/cert-setup.txt" | tail -1) || cert_hash=""
security find-identity -p codesigning "$kc" | grep -q "$cert_hash" 2>/dev/null || {
  echo "self-signed identity not usable:"; cat "$work/cert-setup.txt"; security find-identity -p codesigning "$kc"; cert_hash=""; }

builds="first second"
[ -n "$cert_hash" ] && builds="$builds certfirst certsecond"
for build in $builds; do
  cp "$here/keychain-probe.swift" "$work/$build.swift"
  echo "let build = \"$build\"" >> "$work/$build.swift"
  xcrun swiftc -O "$work/$build.swift" -o "$work/$build" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$work/Info.plist"
  case $build in
    cert*) sign=(-s "$cert_hash" --keychain "$kc") ;;
    *) sign=(-s -) ;;
  esac
  codesign "${sign[@]}" -f -i com.praxstack.ledgeratlas.keychain-probe \
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
run "$work/first" write adhoc
run "$work/second" read adhoc
echo "| | **self-signed certificate builds** | |" >> "$work/result.md"
if [ -n "$cert_hash" ]; then
  run "$work/certfirst" write cert
  run "$work/certsecond" read cert
else
  echo "| cert | could not create a signing identity | |" >> "$work/result.md"
fi
cat "$work/result.md"
[ -s "$work/stderr.txt" ] && { echo "stderr:"; cat "$work/stderr.txt"; }
for b in $builds; do codesign -d -r- "$work/$b" 2>&1 | tail -1; done
security delete-keychain "$kc" 2>/dev/null || true
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Keychain probe (ad-hoc, sandboxed, optimized)"; cat "$work/result.md"; } >> "$GITHUB_STEP_SUMMARY"
fi
