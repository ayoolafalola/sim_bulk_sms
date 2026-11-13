#!/usr/bin/env bash
# Builds the next Google Play release: bumps the build number in pubspec.yaml (1.0.0+2 -> 1.0.0+3),
# builds the signed app bundle, checks it's signed with the upload key, keeps a copy of the
# bundle and its debug info (for crash reports) under build/releases/<version>/, and with
# --upload sends it to Google Play.
#
#   tool/release_android.sh            # next build number, same version name
#   tool/release_android.sh 1.0.1      # new version name (also updates appVersion in lib/app/app_info.dart)
#   tool/release_android.sh --bump-only [1.0.1]   # only change the numbers, don't build
#   tool/release_android.sh --no-bump              # build the version already in pubspec.yaml
# Options (after the above):
#   --upload[=TRACK]   upload to Google Play: internal (default), alpha, beta or production
#   --notes=TEXT       "What's new" for Play (default: RELEASE_NOTES.txt, if there is one)
#
# Checks for 8 GB of free disk first (freeing rebuildable files if needed) and clears
# the build caches when it ends; signed releases and debug info are kept (tool/disk.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
command -v flutter >/dev/null || export PATH="$HOME/flutter/bin:$PATH"
source tool/disk.sh

UPLOAD_SHA1="C6:82:F7:1C:C8:64:96:53:BD:0E:DB:4D:06:BD:BB:E9:F7:E4:76:67"
BUMP_ONLY=false; NO_BUMP=false; NEW_NAME=""; TRACK=""; NOTES=""
[[ -s RELEASE_NOTES.txt ]] && NOTES="$(head -c 500 RELEASE_NOTES.txt)"
for arg in "$@"; do
  case "$arg" in
    --bump-only) BUMP_ONLY=true ;;
    --no-bump) NO_BUMP=true ;;
    --upload) TRACK=internal ;;
    --upload=*) TRACK="${arg#--upload=}" ;;
    --notes=*) NOTES="${arg#--notes=}" ;;
    [0-9]*.[0-9]*.[0-9]*) NEW_NAME="$arg" ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done
case "$TRACK" in ""|internal|alpha|beta|production) ;; *) echo "Unknown Play track: $TRACK" >&2; exit 2 ;; esac

line=$(grep -E '^version: ' pubspec.yaml)
current=${line#version: }
name=${current%+*}
build=${current#*+}
if [[ -n "$NEW_NAME" ]]; then
  [[ "$NEW_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version name must look like 1.0.1"; exit 1; }
  name="$NEW_NAME"
fi
next="$name+$((build + 1))"
$NO_BUMP && next="$current"

if ! $NO_BUMP; then
  sed -i '' "s/^version: .*/version: $next/" pubspec.yaml
  sed -i '' "s/^const appVersion = '.*';/const appVersion = '$name';/" lib/app/app_info.dart
fi
echo "Version: $current -> $next"
$BUMP_ONLY && exit 0

[[ -f android/key.properties ]] || { echo "android/key.properties is missing: the bundle would be signed with the debug key."; exit 1; }
disk_ensure 8 "$ROOT"
disk_cleanup_on_exit android "$ROOT"

out="build/releases/$next"
mkdir -p "$out"
# Contacts++ API and the Messages++ Firebase app (config/production.example.json).
defines=(); [[ -f config/production.json ]] && defines=(--dart-define-from-file=config/production.json)
if [[ -f config/production.json ]]; then python3 tool/firebase_check.py config/production.json android
else echo "  Note: no config/production.json; chats and web sends arrive only while the app is open."; fi
flutter build appbundle --release --obfuscate --split-debug-info="$out/debug-info" ${defines[@]+"${defines[@]}"}

aab=build/app/outputs/bundle/release/app-release.aab
sha1=$(keytool -printcert -jarfile "$aab" | awk '/SHA1:/ {print $2; exit}')
if [[ "$sha1" != "$UPLOAD_SHA1" ]]; then
  echo "Signed with $sha1, not the upload key ($UPLOAD_SHA1). Don't upload this bundle."
  exit 1
fi
bundle="$out/messages-plus-plus-$next.aab"
cp "$aab" "$bundle"
echo
echo "Signed bundle: $bundle"
echo "Debug info for crash reports: $out/debug-info (keep it)"

if [[ -n "$TRACK" ]]; then
  echo
  echo "▸ Uploading to the Google Play $TRACK track"
  release_name="${next%%+*} (${next##*+})"
  if [[ -n "$NOTES" ]]; then
    python3 tool/play_upload.py "$bundle" --track "$TRACK" --status completed --release-name "$release_name" --notes "$NOTES"
  else
    python3 tool/play_upload.py "$bundle" --track "$TRACK" --status completed --release-name "$release_name"
  fi
fi
