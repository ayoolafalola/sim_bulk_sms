# Background sending: phone test checklist (Android)

1. Open the app → gear icon (Background sending). Fix every item until it says **Ready**.
   On Samsung also add the app under Settings › Battery › Background usage limits › Never sleeping apps.
2. **Manual send, leave the app:** start a campaign to 3+ numbers you own, press Home. The "Sending …" notification
   should show progress, then a result notification. Reopen: statuses are Sent/Delivered.
3. **Pause/Cancel from the app:** start a send to 5+ numbers, tap Pause after the first. It stops after the current
   message; Resume continues. Try Cancel: remaining recipients become Cancelled and are never sent.
4. **Scheduled, app closed:** schedule a weekly run 5 minutes ahead (today's day). Swipe the app away from recents,
   lock the phone. At the time: progress notification, then result. The schedule shows "Next run" next week.
5. **Missed:** schedule 3 minutes ahead, switch the phone off for 2h+ (or turn Alarms & reminders off and keep the
   app closed past 2 hours). Opening the app later records "Skipped: more than 2 hours late"; nothing is sent.
6. **Reboot:** schedule 10 minutes ahead, restart the phone, don't open the app. It should still send.
7. **No exact alarms:** turn Alarms & reminders off. The dashboard warns; a due run starts when you open the app.

If anything fails, note the step, what you saw, and run `adb logcat -s SimBulkSms flutter` while reproducing.
