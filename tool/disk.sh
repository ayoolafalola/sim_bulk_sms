# Disk space for release and deploy scripts. Source it, then:
#
#   disk_ensure 15 "$APP_DIR"          # stop unless 15 GB are free, freeing rebuildable files if needed
#   disk_cleanup_on_exit ios "$APP_DIR" # when the script ends (done or failed), clear build caches
#
# App folders are Flutter apps whose build/ output may be cleared. The kinds for
# disk_cleanup_on_exit say which caches the script fills: ios (Xcode), android
# (Gradle), or none.
#
# Only rebuildable files are removed. Always kept: signed releases
# (build/releases), deploy logs, crash-report debug info (*debug-info),
# exported .ipa files (build/ios/ipa), downloaded dependencies (Gradle
# modules, pub cache, Pods), simulators and their data, Xcode archives, the
# Trash and anything outside these caches.
# Same file in Contacts++ (mobile/tool/disk.sh) and Messages++ (tool/disk.sh).

disk_free_gb() { df -g "$HOME" | awk 'NR == 2 { print $4 }'; }

# An app's build/ output, except what must be kept (see above).
_disk_clear_app_build() {
  local app="$1" item name sub
  [[ -d "$app/build" ]] || return 0
  for item in "$app"/build/* "$app"/build/.[!.]*; do
    [[ -e "$item" ]] || continue
    name="${item##*/}"
    case "$name" in
      releases | deploy-logs | *debug-info*) continue ;;
      ios)
        for sub in "$item"/* "$item"/.[!.]*; do
          [[ -e "$sub" && "${sub##*/}" != ipa ]] && rm -rf "$sub"
        done
        ;;
      *) rm -rf "$item" ;;
    esac
  done
  return 0
}

_disk_clear_xcode() {
  rm -rf "$HOME/Library/Developer/Xcode/DerivedData/"* "$HOME/Library/Developer/CoreSimulator/Caches/"* 2>/dev/null
  xcrun simctl delete unavailable >/dev/null 2>&1
  return 0
}

_disk_clear_gradle() {
  rm -rf "$HOME/.gradle/caches/build-cache-"* 2>/dev/null
  find "$HOME/.gradle/daemon" -name '*.log' -type f -delete 2>/dev/null
  return 0
}

# Gradle's unpacked/transformed libraries: rebuilt from the downloaded ones, no network needed.
_disk_clear_gradle_transforms() {
  rm -rf "$HOME/.gradle/caches/"*/transforms "$HOME/.gradle/caches/transforms-"* 2>/dev/null
  return 0
}

# Device support for iPhones not connected in 30 days (Xcode copies it again when one is).
_disk_clear_old_device_support() {
  local dir
  for dir in "$HOME/Library/Developer/Xcode/iOS DeviceSupport" "$HOME/Library/Developer/Xcode/watchOS DeviceSupport"; do
    [[ -d "$dir" ]] && find "$dir" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2>/dev/null
  done
  rm -rf "$HOME/Library/Caches/CocoaPods/"* "$HOME/Library/Caches/com.apple.dt.Xcode/"* 2>/dev/null
  return 0
}

# disk_ensure GB [app folders...]: succeeds when GB are free, after freeing
# rebuildable files step by step if needed; fails (status 1) otherwise.
disk_ensure() {
  local need="$1"; shift
  local free step label app
  free="$(disk_free_gb)"
  if (( free >= need )); then
    echo "▸ Disk: $free GB free (this needs $need GB)"
    return 0
  fi
  echo "▸ Disk: only $free GB free and this needs $need GB; freeing rebuildable files"
  for step in apps xcode gradle transforms device_support; do
    case "$step" in
      apps) label="old build output"; for app in "$@"; do _disk_clear_app_build "$app"; done ;;
      xcode) label="Xcode build caches"; _disk_clear_xcode ;;
      gradle) label="Gradle build cache"; _disk_clear_gradle ;;
      transforms) label="Gradle's unpacked libraries"; _disk_clear_gradle_transforms ;;
      device_support) label="old iPhone device support and download caches"; _disk_clear_old_device_support ;;
    esac
    free="$(disk_free_gb)"
    echo "  cleared $label: $free GB free"
    (( free >= need )) && return 0
  done
  echo "✗ Still only $free GB free; this needs $need GB. Empty the Trash or move large files off this Mac, then run again." >&2
  return 1
}

# disk_cleanup KINDS [app folders...]: clears what the build left behind.
# KINDS: comma-separated ios, android, none.
disk_cleanup() {
  local kinds="$1"; shift
  local before app
  before="$(disk_free_gb)"
  for app in "$@"; do _disk_clear_app_build "$app"; done
  case ",$kinds," in *,ios,*) _disk_clear_xcode ;; esac
  case ",$kinds," in *,android,*) _disk_clear_gradle ;; esac
  echo "▸ Cleared build caches: $(disk_free_gb) GB free (was $before GB)"
  return 0
}

# Runs disk_cleanup when the script ends, keeping its exit status. Chains an
# EXIT trap the script set before (pass it as DISK_PREVIOUS_EXIT_TRAP).
disk_cleanup_on_exit() {
  _DISK_CLEANUP_ARGS=("$@")
  trap '_disk_status=$?; eval "${DISK_PREVIOUS_EXIT_TRAP:-:}"; disk_cleanup "${_DISK_CLEANUP_ARGS[@]}" || true; exit $_disk_status' EXIT
}
