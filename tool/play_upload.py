#!/usr/bin/env python3
"""Uploads a Messages++ App Bundle to Google Play and puts it on a track.

A copy of Contacts++'s mobile/tool/play_upload.py, for com.comeriver.messages.

Uses the Google Play Developer API with a service account key (JSON). The
key never leaves this machine except to sign Google's login token, and it
is never printed. The service account needs Release access to Messages++
in Play Console (Users and permissions).

Usage:
  tool/play_upload.py BUNDLE.aab [--track internal] [--status completed]
      [--release-name "1.0.1 (5)"] [--notes "What's new"] [--notes-language en-US]
      [--dry-run]

The service account key is read from --key, $PLAY_SERVICE_ACCOUNT_JSON, or
~/keys/play-service-account.json, in that order.
"""
import argparse
import base64
import json
import os
import subprocess
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PACKAGE = os.environ.get("PLAY_PACKAGE", "com.comeriver.messages")
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
# Overridable so the flow can be tested against a local fake.
API = os.environ.get("PLAY_API_BASE", "https://androidpublisher.googleapis.com")
UPLOAD_API = os.environ.get("PLAY_UPLOAD_BASE", API)
DEFAULT_KEY = os.path.expanduser("~/keys/play-service-account.json")


def fail(message):
    print(f"✗ {message}", file=sys.stderr)
    sys.exit(1)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def prefer_ipv4():
    """Connects to Google over IPv4. On some networks the IPv6 route to
    oauth2.googleapis.com and androidpublisher accepts the connection and
    then never answers, so the upload sat at its first step."""
    resolve = socket.getaddrinfo

    def ipv4_first(host, port, family=0, *rest, **kw):
        try:
            return resolve(host, port, socket.AF_INET, *rest, **kw)
        except socket.gaierror:
            return resolve(host, port, family, *rest, **kw)

    socket.getaddrinfo = ipv4_first


def access_token(key):
    """Exchanges a token signed with the service account key for an access token."""
    now = int(time.time())
    header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = b64url(json.dumps({
        "iss": key["client_email"], "scope": SCOPE, "aud": key["token_uri"],
        "iat": now, "exp": now + 3600,
    }).encode())
    unsigned = f"{header}.{claims}".encode()
    with tempfile.TemporaryDirectory() as private_dir:
        os.chmod(private_dir, 0o700)
        key_path = os.path.join(private_dir, "key.pem")
        with open(os.open(key_path, os.O_WRONLY | os.O_CREAT, 0o600), "w") as handle:
            handle.write(key["private_key"])
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                                input=unsigned, capture_output=True, check=False)
    if signed.returncode != 0:
        fail("Could not sign the login token with the service account key.")
    assertion = f"{header}.{claims}.{b64url(signed.stdout)}"
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion,
    }).encode()
    return request("POST", key["token_uri"], body, {"Content-Type": "application/x-www-form-urlencoded"})["access_token"]


def request(method, url, body=None, headers=None):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=600) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        try:
            detail = json.loads(detail).get("error", {}).get("message", detail)
        except ValueError:
            pass
        hint = ""
        lowered = detail.lower()
        if "has already been used" in lowered:
            hint = "\n  Each upload needs a new version code: rebuild with release_android.sh (it bumps the number)."
        elif "draft app" in lowered:
            hint = "\n  The app isn't published on any track yet: rerun with --status draft."
        elif "permission" in lowered and ("photo" in lowered or "declar" in lowered or "core functionality" in lowered):
            hint = ("\n  This is a Play policy check on the permissions the app declares, not a login problem."
                    "\n  Remove the permission from AndroidManifest.xml, or fill in the declaration in"
                    " Play Console → Policy → App content.")
        elif error.code == 401 or "caller does not have permission" in lowered or "not authorized" in lowered:
            hint = ("\n  Check the service account has Release permissions for this app in"
                    " Play Console → Users and permissions.")
        fail(f"Google Play API {method} {urllib.parse.urlparse(url).path}: {error.code} {detail}{hint}")


CHUNK = 8 * 1024 * 1024


def resumable_upload(start_url, path, auth):
    """Sends the bundle in 8 MB pieces, retrying each and resuming where the
    server says it stopped, so a slow or unsteady connection can't fail the
    whole upload the way one large request did."""
    total = os.path.getsize(path)
    session = urllib.request.Request(start_url, data=b"", method="POST", headers={
        **auth, "X-Upload-Content-Type": "application/octet-stream", "X-Upload-Content-Length": str(total),
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(session, timeout=120) as response:
        location = response.headers["Location"]
    offset = 0
    failures = 0
    with open(path, "rb") as bundle:
        while True:
            if offset >= total:
                # Finished during an interruption: the status call returns
                # the uploaded bundle.
                done = urllib.request.Request(location, data=b"", method="PUT", headers={
                    **auth, "Content-Length": "0", "Content-Range": f"bytes */{total}",
                })
                with urllib.request.urlopen(done, timeout=60) as response:
                    return json.loads(response.read())
            bundle.seek(offset)
            chunk = bundle.read(CHUNK)
            end = offset + len(chunk) - 1
            req = urllib.request.Request(location, data=chunk, method="PUT", headers={
                **auth, "Content-Length": str(len(chunk)), "Content-Range": f"bytes {offset}-{end}/{total}",
            })
            try:
                with urllib.request.urlopen(req, timeout=300) as response:
                    print("  uploaded 100%")
                    return json.loads(response.read())
            except urllib.error.HTTPError as error:
                if error.code != 308:
                    if error.code >= 500 and failures < 5:
                        failures += 1
                        time.sleep(2 ** failures)
                        offset = uploaded_until(location, total, auth)
                        continue
                    detail = error.read().decode(errors="replace")
                    fail(f"Google Play upload: {error.code} {detail}")
                received = error.headers.get("Range")
                offset = int(received.split("-")[1]) + 1 if received else 0
                failures = 0
                print(f"  uploaded {offset * 100 // total}%")
            except (urllib.error.URLError, TimeoutError, OSError):
                failures += 1
                if failures > 5:
                    fail("Google Play upload kept timing out; try again on a steadier connection.")
                time.sleep(2 ** failures)
                offset = uploaded_until(location, total, auth)


def uploaded_until(location, total, auth):
    """Asks how much of the upload the server has, after an interruption."""
    req = urllib.request.Request(location, data=b"", method="PUT", headers={
        **auth, "Content-Length": "0", "Content-Range": f"bytes */{total}",
    })
    try:
        with urllib.request.urlopen(req, timeout=60):
            return total
    except urllib.error.HTTPError as error:
        received = error.headers.get("Range") if error.code == 308 else None
        return int(received.split("-")[1]) + 1 if received else 0
    except (urllib.error.URLError, TimeoutError, OSError):
        return 0


def main():
    parser = argparse.ArgumentParser(description="Upload an App Bundle to Google Play.")
    parser.add_argument("bundle")
    parser.add_argument("--track", default="internal", help="internal, alpha (closed), beta (open) or production")
    parser.add_argument("--status", default="completed", choices=["completed", "draft"],
                        help="completed rolls it out to the track; draft leaves it for review in Play Console")
    parser.add_argument("--release-name")
    parser.add_argument("--notes", help="What's new text for this release (optional)")
    parser.add_argument("--notes-language", default="en-US",
                        help="Store listing language for --notes, e.g. en-US or en-GB")
    parser.add_argument("--key", help="Service account JSON key")
    parser.add_argument("--dry-run", action="store_true", help="Check the key and bundle without uploading")
    args = parser.parse_args()
    # Progress shows as it happens, also when piped through deploy.sh's tee.
    sys.stdout.reconfigure(line_buffering=True)
    prefer_ipv4()

    if not os.path.isfile(args.bundle):
        fail(f"Bundle not found: {args.bundle}")
    key_path = args.key or os.environ.get("PLAY_SERVICE_ACCOUNT_JSON") or DEFAULT_KEY
    if not os.path.isfile(key_path):
        fail(f"No service account key at {key_path}.")
    if os.stat(key_path).st_mode & 0o077:
        print(f"! {key_path} is readable by other users; run: chmod 600 {key_path}", file=sys.stderr)
    try:
        key = json.load(open(key_path))
        assert key.get("type") == "service_account" and key.get("private_key") and key.get("client_email")
        key.setdefault("token_uri", "https://oauth2.googleapis.com/token")
    except (ValueError, AssertionError):
        fail(f"{key_path} is not a Google service account JSON key.")
    size_mb = os.path.getsize(args.bundle) / 1_048_576
    print(f"Google Play upload: {os.path.basename(args.bundle)} ({size_mb:.1f} MB) → {args.track} track, {args.status}")
    print(f"  as {key['client_email']}")

    token = access_token(key)
    auth = {"Authorization": f"Bearer {token}"}
    if args.dry_run:
        edit = request("POST", f"{API}/androidpublisher/v3/applications/{PACKAGE}/edits", b"{}",
                       {**auth, "Content-Type": "application/json"})
        request("DELETE", f"{API}/androidpublisher/v3/applications/{PACKAGE}/edits/{edit['id']}", headers=auth)
        print("✓ Signed in and reached the app in Play Console. Dry run: nothing uploaded.")
        return

    base = f"{API}/androidpublisher/v3/applications/{PACKAGE}/edits"
    edit_id = request("POST", base, b"{}", {**auth, "Content-Type": "application/json"})["id"]
    print("  uploading bundle…")
    uploaded = resumable_upload(
        f"{UPLOAD_API}/upload/androidpublisher/v3/applications/{PACKAGE}/edits/{edit_id}/bundles?uploadType=resumable",
        args.bundle, auth)
    version_code = str(uploaded["versionCode"])
    release = {"versionCodes": [version_code], "status": args.status}
    if args.release_name:
        release["name"] = args.release_name
    if args.notes:
        release["releaseNotes"] = [{"language": args.notes_language, "text": args.notes}]
    request("PUT", f"{base}/{edit_id}/tracks/{args.track}",
            json.dumps({"track": args.track, "releases": [release]}).encode(),
            {**auth, "Content-Type": "application/json"})
    request("POST", f"{base}/{edit_id}:commit", b"", auth)
    print(f"✓ Version code {version_code} is on the {args.track} track ({args.status}).")


if __name__ == "__main__":
    main()
