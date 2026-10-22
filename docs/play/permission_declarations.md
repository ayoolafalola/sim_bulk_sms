# Play Console declarations (full build)

Fill these in Play Console › Policy and programs › App content. Policy text changes; re-read the linked
policies before submitting. Be accurate: misleading declarations can lead to removal or account suspension.

## 1. SMS permission (`SEND_SMS`) — Permissions Declaration Form

Google Play allows `SEND_SMS` only for default SMS apps and listed exceptions; there is **no bulk/business
messaging exception**. The closest is **"Device automation"** (automating actions based on user-set triggers).
Expect a real chance of refusal; if refused, ship the store build (docs/RELEASE.md) — no code changes needed.
Policy: https://support.google.com/googleplay/android-developer/answer/10208820

- **Core functionality / exception:** Device automation.
- **Description (draft):**
  "Comeriver Messages lets a user send their own text messages to contacts they chose, from their own SIM,
  automatically at times they set. Users create a campaign (message + recipient groups), confirm the cost, and
  either send it now or schedule it (a date and time, or weekly on chosen days). At the scheduled time the app
  sends the messages without further interaction, pausing between messages and respecting user-set hourly and
  daily limits. SEND_SMS is required to perform these user-scheduled sends; the SMS intent cannot send without the
  user being present. The app never reads SMS, is not used for verification, and sends nothing the user did not
  write and schedule."
- **Video:** record the same flow as the foreground-service video below (it shows the scheduled automatic send).

## 2. Foreground service (special use) — Foreground service permissions declaration

- **Type:** `specialUse` · subtype in the manifest: "Sends SMS campaigns that the user started or scheduled,
  through the user's own SIM".
- **Why no standard type fits:** sending a user-started batch of SMS with pauses between messages is not media,
  location, data sync, phone call, etc.; it may take minutes to hours because of the user's send limits.
- **User impact if deferred/stopped:** the user's scheduled messages go out late or not at all.
- **Video script (30–60 s, screen recording on a phone):**
  1. Open the app, open a ready campaign with 3 test recipients, tap Send, confirm.
  2. Show the ongoing "Sending …" notification, press Home, show messages continuing.
  3. Open a campaign › Schedule… › Repeat weekly, set a time 2 minutes ahead, save.
  4. Close the app (swipe away); show the notification appearing at the time and the result notification.

## 3. Exact alarms

The app uses `SCHEDULE_EXACT_ALARM` (granted by the user under Alarms & reminders), not `USE_EXACT_ALARM`.
Justification if asked: "Starts the user's scheduled SMS campaigns at the time the user chose, and resumes a
campaign paused by the user's own hourly/daily limit."

## 4. Battery optimisation exemption (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`)

Play restricts this permission to apps whose core function is broken by battery optimisation. Justification:
"Scheduled campaigns must start at the user-chosen time with the screen off; on many phones battery
optimisation delays or cancels them." **Risk:** if this is questioned, removing it from the full build is a
one-line change (the setup screen then opens the general battery settings list instead).

## 5. Contacts (`READ_CONTACTS`)

Not a restricted permission. Used only for "Import from phone", only after the user taps it; names and numbers
stay on the device. Covered by the privacy policy and the in-app explanation in setup.

## 6. Other App content items

- **Privacy policy:** the GitHub Pages URL.
- **Ads:** No ads. **App access:** All functionality available without special access (no login).
- **Content rating:** answer the questionnaire (communication app, no user-generated public content, no
  sharing of location). **Target audience:** 18+ (business/organisations).
- **Data safety:** see data_safety.md.
