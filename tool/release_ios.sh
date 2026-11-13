#!/usr/bin/env bash
# Messages++ (com.comeriver.messages) for the App Store: builds, signs and
# uploads to App Store Connect (TestFlight), then optionally fills the listing.
# Unattended: signing uses the Comeriver App Store Connect API key
# (Xcode creates or renews certificates and profiles itself).
#
#   tool/release_ios.sh               # build and upload the version in pubspec.yaml
#   tool/release_ios.sh --bump        # next build number first (1.0.1+3 → 1.0.1+4)
#   tool/release_ios.sh --no-upload   # build and export the .ipa only
#   tool/release_ios.sh --wait        # wait until TestFlight has processed it
#   tool/release_ios.sh --listing     # with --wait: then fill the listing and attach the build
#   tool/release_ios.sh --checks      # run flutter analyze and flutter test first
#
# Release settings: config/production.json (copy config/production.example.json:
# Contacts++ API and the Messages++ Firebase app). Key: ASC_KEY_ID / ASC_ISSUER_ID /
# ASC_KEY_PATH (defaults: Comeriver's key in ~/keys). Logs: build/deploy-logs/.
# Submitting for review stays a deliberate step in App Store Connect.
# Checks for 15 GB of free disk first (freeing rebuildable files if needed) and clears
# the build caches when it ends; signed releases, the .ipa and debug info are kept.
set -euo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FLUTTER="${FLUTTER:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}"
export ASC_KEY_ID="${ASC_KEY_ID:-Y7FF33SVW9}"
export ASC_ISSUER_ID="${ASC_ISSUER_ID:-4f0ab896-ee2f-453c-a7d7-ea6e950c4a58}"
export ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/keys/AuthKey_$ASC_KEY_ID.p8}"
TEAM_ID="9S84UDUKSQ"
CONFIG="$ROOT/config/production.json"
ARCHIVE="$ROOT/build/ios/archive/Runner.xcarchive"
EXPORT="$ROOT/build/ios/ipa"
LOG_DIR="$ROOT/build/deploy-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/ios-$(date +%Y%m%d-%H%M%S).log"

upload=1; wait_for_processing=0; listing=0; checks=0; bump=0
for arg in "$@"; do
  case "$arg" in
    --no-upload) upload=0 ;;
    --wait) wait_for_processing=1 ;;
    --listing) listing=1; wait_for_processing=1 ;;
    --checks) checks=1 ;;
    --bump) bump=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

fail() { echo "iOS release failed: $*" >&2; echo "Full log: $LOG" >&2; exit 1; }
step() { echo "▸ $*"; }

source "$ROOT/tool/disk.sh"
disk_ensure 15 "$ROOT" || fail "Not enough free disk space for an iOS archive."
disk_cleanup_on_exit ios "$ROOT"

[[ -f "$ASC_KEY_PATH" ]] || fail "App Store Connect key not found at $ASC_KEY_PATH."
[[ -f "$CONFIG" ]] || fail "Missing $CONFIG: copy config/production.example.json and fill in the Messages++ Firebase app."
python3 "$ROOT/tool/firebase_check.py" "$CONFIG" ios
(( bump )) && tool/release_android.sh --bump-only
version="$(sed -n 's/^version: *//p' pubspec.yaml | tr -d '[:space:]')"
[[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]] || fail "pubspec.yaml version '$version' is not X.Y.Z+N."
name="${BASH_REMATCH[1]}"; build="${BASH_REMATCH[2]}"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

step "Messages++ iOS $name ($build)"
step "Checking App Store Connect"
python3 tool/asc_api.py check >>"$LOG" 2>&1 || fail "App Store Connect API check failed (see log)."
python3 tool/asc_api.py ensure-bundle-ids >>"$LOG" 2>&1 || fail "Couldn't register the bundle IDs (see log)."

if (( checks )); then
  step "Analyzing and testing"
  "$FLUTTER" analyze >>"$LOG" 2>&1 || fail "flutter analyze found problems."
  "$FLUTTER" test >>"$LOG" 2>&1 || fail "Tests failed."
fi

step "Preparing Flutter and CocoaPods"
"$FLUTTER" pub get >>"$LOG" 2>&1 || fail "flutter pub get failed."
ruby ios/tool/configure_native_integration.rb >>"$LOG" 2>&1 || fail "Couldn't configure the Share Extension target."
"$FLUTTER" build ios --release --config-only --obfuscate --split-debug-info=build/ios-debug-info \
  --dart-define-from-file="$CONFIG" >>"$LOG" 2>&1 || fail "flutter build ios --config-only failed."

step "Archiving (signed automatically with the API key)"
rm -rf "$ARCHIVE"
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" \
  "${AUTH[@]}" archive >>"$LOG" 2>&1 \
  || { grep -E "^error:|error: " "$LOG" | tail -8 >&2; fail "Archive failed."; }

options="$ROOT/build/ios/ExportOptions-export.plist"
mkdir -p "$(dirname "$options")"
sed 's#<string>upload</string>#<string>export</string>#' "$ROOT/ios/ExportOptions.plist" >"$options"
step "Exporting the signed .ipa"
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$options" \
  -exportPath "$EXPORT" "${AUTH[@]}" >>"$LOG" 2>&1 \
  || { grep -E "^error:|error: " "$LOG" | tail -8 >&2; fail "Export failed."; }
ipa="$(ls "$EXPORT"/*.ipa 2>/dev/null | head -1)"
[[ -n "$ipa" ]] || fail "No .ipa was exported."
mkdir -p "build/releases/$name+$build" && cp "$ipa" "build/releases/$name+$build/messages-plus-plus-$name+$build.ipa"

if (( ! upload )); then step "Done: $ipa"; exit 0; fi

step "Uploading to App Store Connect"
xcrun altool --upload-app -f "$ipa" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH" >>"$LOG" 2>&1 \
  || { grep -iE "error|fail" "$LOG" | tail -8 >&2; fail "Upload failed."; }
step "Uploaded $name ($build). TestFlight processes it in about 10–30 minutes."

if (( wait_for_processing )); then
  state=UNKNOWN
  for _ in $(seq 1 80); do
    state="$(python3 tool/asc_api.py build-status "$name" "$build" 2>>"$LOG" || echo UNKNOWN)"
    case "$state" in
      VALID) step "TestFlight: ready to test"; break ;;
      INVALID|FAILED) fail "App Store Connect rejected the build ($state); check email from Apple." ;;
      *) sleep 30 ;;
    esac
  done
  if (( listing )) && [[ "$state" == VALID ]]; then
    step "Filling the App Store listing and attaching build $build"
    python3 tool/asc_listing.py "$build" || fail "Listing incomplete (see above)."
  fi
fi
echo "Log: $LOG"
echo "Next: App Store Connect › Messages++ › App Privacy (docs/IOS_RELEASE.md §4), the Comeriver Pro"
echo "subscriptions (§5), then Add for Review › Submit."
