#!/usr/bin/env bash
# Releases Messages++ everywhere in one go. Stops at the first failure.
#
#   1. Checks free disk space (15 GB with iOS, 8 GB for Android only),
#      freeing rebuildable files if needed (tool/disk.sh).
#   2. Optionally analyzes and tests (--checks).
#   3. One version bump for both stores: version name and build number
#      (patch by default: 1.0.1+8 → 1.0.2+9).
#   4. Android: builds and signs the bundle, uploads it to Google Play
#      (internal testing track, or production with --production).
#   5. iOS: builds, signs and uploads to App Store Connect, waits for
#      processing, then fills the listing and attaches the build to the
#      App Store version.
#   6. Website: messages.comeriver.com (landing page, web app, developer guide).
#   7. Clears the build caches (signed releases, logs and crash-report debug
#      info are kept), also after a failure.
#
# "What's new" for both stores comes from RELEASE_NOTES.txt when it exists.
# Submitting the iOS version for review stays a click in App Store Connect.
#
#   tool/release.sh                 # patch release; Android, iOS, website
#   tool/release.sh minor           # 1.0.1 → 1.1.0 (or major, or an exact 1.2.0)
#   tool/release.sh --production    # Android to everyone on Play (default: internal testing)
# Options: --no-android --no-ios --no-site --checks --track=alpha|beta
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
command -v flutter >/dev/null || export PATH="$HOME/flutter/bin:$PATH"
source tool/disk.sh

android=1; ios=1; site=1; checks=0; bump=patch; track=internal
for arg in "$@"; do
  case "$arg" in
    --no-android) android=0 ;;
    --no-ios) ios=0 ;;
    --no-site) site=0 ;;
    --checks) checks=1 ;;
    --production) track=production ;;
    --track=*) track="${arg#--track=}" ;;
    --listing) ;; # always on now; accepted so old commands still work
    patch|minor|major|[0-9]*.[0-9]*.[0-9]*) bump="$arg" ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

started=$SECONDS
done_parts=()
notify() { osascript -e "display notification \"$2\" with title \"Messages++ release\" subtitle \"$1\"" >/dev/null 2>&1 || true; }
finish() {
  local status=$?
  disk_cleanup ios,android "$ROOT" || true
  if (( status != 0 )); then
    echo
    echo "✗ Release stopped. Already done: ${done_parts[*]:-nothing}."
    notify "Stopped" "Already done: ${done_parts[*]:-nothing}"
  fi
  exit $status
}
trap finish EXIT

need=1
(( android )) && need=8
(( ios )) && need=15
disk_ensure "$need" "$ROOT"

if (( checks )); then
  echo "▸ Analyzing and testing"
  flutter analyze --no-fatal-infos
  flutter test
fi

current="$(sed -n 's/^version: *//p' pubspec.yaml | tr -d '[:space:]')"
[[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\+[0-9]+$ ]] || { echo "pubspec.yaml version '$current' is not X.Y.Z+N." >&2; exit 1; }
case "$bump" in
  patch) name="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))" ;;
  minor) name="${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1)).0" ;;
  major) name="$((BASH_REMATCH[1] + 1)).0.0" ;;
  *) name="$bump" ;;
esac
tool/release_android.sh --bump-only "$name"
version="$(grep -E '^version: ' pubspec.yaml | cut -d' ' -f2)"

if (( android )); then
  echo
  echo "━━ Android $version → Google Play ($track) ━━"
  tool/release_android.sh --no-bump "--upload=$track"
  done_parts+=("Android ($track)")
fi
if (( ios )); then
  echo
  echo "━━ iOS $version → App Store Connect ━━"
  tool/release_ios.sh --wait --listing
  done_parts+=("iOS")
fi
if (( site )); then
  echo
  echo "━━ Website ━━"
  tool/deploy_site.sh
  done_parts+=("website")
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "✓ Messages++ $version released in $(( (SECONDS - started) / 60 )) min: ${done_parts[*]:-nothing}"
(( android )) && echo "  Android is on the Google Play $track track."
(( ios )) && echo "  iOS is processed and attached to the App Store version: submit it for review in App Store Connect."
echo "════════════════════════════════════════════════════════════"
notify "Released $version" "${done_parts[*]:-nothing}"
