#!/usr/bin/env bash
# Builds the next Google Play release: bumps the build number in pubspec.yaml (1.0.0+2 -> 1.0.0+3),
# builds the signed app bundle, checks it's signed with the upload key, and keeps a copy of the
# bundle and its debug info (for crash reports) under build/releases/<version>/.
#
#   tool/release_android.sh            # next build number, same version name
#   tool/release_android.sh 1.0.1      # new version name (also updates appVersion in lib/app/app_info.dart)
#   tool/release_android.sh --bump-only [1.0.1]   # only change the numbers, don't build
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD_SHA1="C6:82:F7:1C:C8:64:96:53:BD:0E:DB:4D:06:BD:BB:E9:F7:E4:76:67"
BUMP_ONLY=false
if [[ "${1:-}" == "--bump-only" ]]; then BUMP_ONLY=true; shift; fi
NEW_NAME="${1:-}"

line=$(grep -E '^version: ' pubspec.yaml)
current=${line#version: }
name=${current%+*}
build=${current#*+}
if [[ -n "$NEW_NAME" ]]; then
  [[ "$NEW_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version name must look like 1.0.1"; exit 1; }
  name="$NEW_NAME"
fi
next="$name+$((build + 1))"

sed -i '' "s/^version: .*/version: $next/" pubspec.yaml
sed -i '' "s/^const appVersion = '.*';/const appVersion = '$name';/" lib/app/app_info.dart
echo "Version: $current -> $next"
$BUMP_ONLY && exit 0

[[ -f android/key.properties ]] || { echo "android/key.properties is missing: the bundle would be signed with the debug key."; exit 1; }

out="build/releases/$next"
mkdir -p "$out"
flutter build appbundle --release --obfuscate --split-debug-info="$out/debug-info"

aab=build/app/outputs/bundle/release/app-release.aab
sha1=$(keytool -printcert -jarfile "$aab" | awk '/SHA1:/ {print $2; exit}')
if [[ "$sha1" != "$UPLOAD_SHA1" ]]; then
  echo "Signed with $sha1, not the upload key ($UPLOAD_SHA1). Don't upload this bundle."
  exit 1
fi
cp "$aab" "$out/messages-plus-plus-$next.aab"
echo
echo "Ready to upload: $out/messages-plus-plus-$next.aab"
echo "Debug info for crash reports: $out/debug-info (keep it)"
