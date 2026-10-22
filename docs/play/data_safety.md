# Data safety form (draft answers)

Basis: the app has no server, account, analytics, ads or crash-reporting SDK. Contacts, campaigns, messages and
send history stay on the phone (the app's database and Android's own message store). Re-check these answers if
you ever add an SDK or a server.

Play counts data as "collected" when it is sent off the device by the app, including to a service the *user*
chose, unless it is only processed in a way the user expects as the app's core function. Answer conservatively:

## Collected

- **Does your app collect or share any of the required user data types?** Yes, because campaign emails are sent
  through an email service the user sets up (their Mailgun-compatible provider or their Gmail).
- **Personal info › Email address** and **Name** (of the email's recipients), and **Messages › Other in-app
  messages** (the email subject and text):
  - Collected: Yes. Shared: No (sent at the user's request to the user's own email provider, which Play treats
    as a user-initiated transfer, not sharing).
  - Processed ephemerally: Yes (the app sends them and keeps nothing off the device).
  - Required or optional: Optional (only when the user turns on email).
  - Purpose: App functionality.

## Subscriptions

- **Financial info › Purchase history:** Not collected. Comeriver Pro is bought through Google Play Billing; the
  app only asks Play whether a subscription is active and keeps that on the phone. Nothing is sent to us.

## Not collected

- **SMS and MMS:** read, sent and stored only on the phone, through the user's carrier, at the user's request.
- **Contacts:** synced from the phone's contacts into the app's database on the phone; never uploaded.
- **App activity, device ids, location, financial info, health, photos, files:** not collected.

## Other questions

- **Is all user data encrypted in transit?** Yes: email goes over HTTPS (the app refuses non-https email APIs).
- **Do you provide a way for users to request deletion?** Data is on the device: users delete contacts,
  conversations and campaigns in the app, disconnect Gmail in Settings › Email, or remove everything by
  uninstalling or clearing the app's storage. Emails already sent are held by the user's own email provider.
- **Independent security review:** No.
