#!/usr/bin/env python3
"""Minimal App Store Connect API client for Messages++ releases (copied from
Contacts++'s mobile/tool/asc_api.py; same Comeriver team key).

Credentials come from the environment (defaults are Comeriver's team key):
  ASC_KEY_ID       App Store Connect API key ID         (default Y7FF33SVW9)
  ASC_ISSUER_ID    Issuer ID                             (default Comeriver's)
  ASC_KEY_PATH     Path to AuthKey_<id>.p8               (default ~/keys/AuthKey_<id>.p8)

Never prints the key or the token.

Usage:
  asc_api.py check                    API reachable; app record and bundle IDs
  asc_api.py ensure-bundle-ids        Registers the app and extension bundle IDs
  asc_api.py build-status <version> <build>   Processing state of an uploaded build
  asc_api.py get <path>               Raw GET (JSON) for debugging
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

KEY_ID = os.environ.get("ASC_KEY_ID", "Y7FF33SVW9")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "4f0ab896-ee2f-453c-a7d7-ea6e950c4a58")
KEY_PATH = os.path.expanduser(os.environ.get("ASC_KEY_PATH", f"~/keys/AuthKey_{KEY_ID}.p8"))
API = "https://api.appstoreconnect.apple.com"

APP_BUNDLE = os.environ.get("ASC_APP_BUNDLE", "com.comeriver.messages")
BUNDLE_IDS = {
    APP_BUNDLE: "Messages Plus",  # Apple refuses "+" in bundle ID names.
    f"{APP_BUNDLE}.ShareExtension": "Messages Plus Share",
}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token() -> str:
    with open(KEY_PATH, "rb") as handle:
        key = serialization.load_pem_private_key(handle.read(), password=None)
    header = b64url(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    now = int(time.time())
    claims = b64url(json.dumps({"iss": ISSUER_ID, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{claims}".encode()
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    return f"{header}.{claims}.{b64url(signature)}"


def call(method: str, path: str, body=None):
    request = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        try:
            detail = "; ".join(e.get("detail") or e.get("title", "") for e in json.loads(detail).get("errors", []))
        except ValueError:
            pass
        raise SystemExit(f"App Store Connect {method} {path.split('?')[0]} failed ({error.code}): {detail}")


def bundle_ids():
    data = call("GET", "/v1/bundleIds?limit=200&fields[bundleIds]=identifier,name,platform")["data"]
    return {item["attributes"]["identifier"]: item["id"] for item in data}


def app_record():
    data = call("GET", f"/v1/apps?filter[bundleId]={APP_BUNDLE}&fields[apps]=name,bundleId,sku")["data"]
    return data[0] if data else None


def check():
    app = app_record()
    print("API: reachable")
    print(f"App record: {app['attributes']['name']} ({app['id']})" if app else "App record: none (create it in App Store Connect)")
    known = bundle_ids()
    for identifier in BUNDLE_IDS:
        print(f"Bundle ID {identifier}: {'registered' if identifier in known else 'missing'}")
    return app


def ensure_bundle_ids():
    known = bundle_ids()
    for identifier, name in BUNDLE_IDS.items():
        if identifier in known:
            continue
        call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": identifier, "name": name, "platform": "IOS"}}})
        print(f"Registered {identifier}")
    print("Bundle IDs ready")


def build_status(version: str, number: str):
    app = app_record()
    if not app:
        raise SystemExit("No app record")
    path = (f"/v1/builds?filter[app]={app['id']}&filter[version]={number}"
            f"&filter[preReleaseVersion.version]={version}&fields[builds]=processingState,version,uploadedDate")
    data = call("GET", path)["data"]
    print(data[0]["attributes"]["processingState"] if data else "NOT_FOUND")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    command = sys.argv[1]
    if command == "check":
        check()
    elif command == "ensure-bundle-ids":
        ensure_bundle_ids()
    elif command == "build-status" and len(sys.argv) == 4:
        build_status(sys.argv[2], sys.argv[3])
    elif command == "get" and len(sys.argv) == 3:
        print(json.dumps(call("GET", sys.argv[2]), indent=2))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
