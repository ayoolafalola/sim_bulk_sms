#!/usr/bin/env bash
# Publishes site/ (landing page, web app at /app, developer guide at /developers)
# to messages.comeriver.com on the Comeriver web host, then checks it answers.
#
#   tool/deploy_site.sh            # upload and check
#   tool/deploy_site.sh --dry-run  # list what would be uploaded
# Checks for 1 GB of free disk first (the upload is packed locally). It builds
# nothing, so it leaves no build caches behind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_HOST="${WEB_HOST:-shadrack@s19.hoster.ng}"
REMOTE="${MESSAGES_WEB_ROOT:-~/messages.comeriver.com/html}"
SITE="https://messages.comeriver.com"
# One shared SSH connection: the host resets connections opened in quick succession.
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15
  -o ControlMaster=auto -o "ControlPath=/tmp/messages-ssh-%C" -o ControlPersist=60)

source "$ROOT/tool/disk.sh"
disk_ensure 1 || exit 1

if [[ "${1:-}" == "--dry-run" ]]; then
  (cd "$ROOT/site" && find . -type f ! -name .DS_Store | sort)
  exit 0
fi
# Cache-busting: a new link whenever the web app changes (Cloudflare caches scripts).
js="$(md5 -q "$ROOT/site/app/app.js" | cut -c1-10)"; css="$(md5 -q "$ROOT/site/app/app.css" | cut -c1-10)"
sed -i '' -E "s#/app/app\.js(\?v=[0-9a-f]+)?\"#/app/app.js?v=$js\"#; s#/app/app\.css(\?v=[0-9a-f]+)?\"#/app/app.css?v=$css\"#" "$ROOT/site/app/index.html"

upload() {
  "${SSH[@]}" "$WEB_HOST" "mkdir -p $REMOTE" &&
    COPYFILE_DISABLE=1 tar -C "$ROOT/site" --exclude .DS_Store --no-xattrs -czf - . |
    "${SSH[@]}" "$WEB_HOST" "tar -xzf - -C $REMOTE"
}
echo "▸ Uploading site/ to $WEB_HOST:$REMOTE"
for attempt in 1 2 3 4; do
  upload && break
  ((attempt < 4)) || { echo "Couldn't reach $WEB_HOST (check the connection and ssh-add)."; exit 1; }
  echo "  The server dropped the connection; trying again in $((attempt * 10)) s."
  sleep $((attempt * 10))
done
"${SSH[@]}" -O exit "$WEB_HOST" >/dev/null 2>&1 || true

echo "▸ Checking"
for path in / /app/ /app/send /developers/ /privacy/ /terms/; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$SITE$path")"
  echo "  $SITE$path → $code"
  [[ "$code" == 200 ]] || { echo "The site isn't answering properly at $path."; exit 1; }
done
echo "Done."
