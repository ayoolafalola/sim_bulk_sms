# Data safety form (draft answers)

Basis: the app has no server, account, analytics, ads or crash-reporting SDK. Contacts, campaigns, messages and
send history are stored only in the app's database on the phone. Re-check if you ever add an SDK or a server.

- **Does your app collect or share any of the required user data types?** No.
  (Play: data processed only on the device and not sent off it is not "collected".)
- **Messages sent by SMS:** the text and phone number go to the recipients through the user's carrier, at the
  user's explicit request; this is the user's own communication, not data shared with the developer or third parties.
- **Is all user data encrypted in transit?** Not applicable (no data leaves the device to us).
- **Do you provide a way for users to request deletion?** Data is on the device only; users delete contacts and
  campaigns in the app, or remove everything by uninstalling or clearing the app's storage.
- **Independent security review:** No.
