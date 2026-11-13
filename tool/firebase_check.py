#!/usr/bin/env python3
"""Says whether a release build will carry the Messages++ Firebase app.

Usage: tool/firebase_check.py config/production.json android|ios
Prints one line. Never prints keys; the app ID is public in the build anyway.
"""
import json
import sys

path, platform = sys.argv[1], sys.argv[2]
tag = platform.upper()
try:
    with open(path) as f:
        config = json.load(f)
except (OSError, ValueError) as error:
    print(f"  Note: cannot read {path} ({error.__class__.__name__}); chats and web sends arrive only while the app is open.")
    sys.exit(0)

app_id = config.get(f"MESSAGES_FIREBASE_{tag}_APP_ID") or config.get("MESSAGES_FIREBASE_APP_ID") or ""
api_key = config.get(f"MESSAGES_FIREBASE_{tag}_API_KEY") or config.get("MESSAGES_FIREBASE_API_KEY") or ""
project = config.get("MESSAGES_FIREBASE_PROJECT_ID") or ""
sender = config.get("MESSAGES_FIREBASE_MESSAGING_SENDER_ID") or ""

missing = [name for name, value in (("app ID", app_id), ("API key", api_key), ("project ID", project), ("sender ID", sender)) if not value]
if missing:
    print(f"  Note: no {platform} Firebase {', '.join(missing)} in {path}; chats and web sends arrive only while the app is open.")
elif f":{platform}:" not in app_id:
    print(f"  Warning: the {platform} Firebase app ID in {path} is not a {platform} app ({app_id}); push will not work.")
else:
    print(f"  Firebase: {project}, {platform} app {app_id}")
