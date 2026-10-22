# Default messaging app: phone test checklist (Parts B1 + B2)

Keep your previous messaging app installed; you can switch back anytime (Settings › Apps › Default apps › SMS app).
Your old texts are not touched by switching.

1. Open the app › Messages tab › **Make default messaging app** › choose Comeriver Messages. The tab now lists
   your existing conversations with names and unread counts.
2. **Receive with the app closed:** swipe the app away, text yourself from another phone. A notification appears;
   tap it — that conversation opens. Then open your old messaging app: the text is there too (same store).
3. **Reply** in the conversation and with a quick-reply chip. Status goes Sending → Sent (→ Delivered if your
   carrier reports it). Turn on airplane mode and send: it shows "Not sent · tap to try again".
4. **Decline a call with "Reply with message"**: the text is sent and appears in that conversation.
5. **From another app:** Contacts app › a contact › message icon. This app opens that conversation.
6. **Campaign:** send a campaign to two of your numbers: each message appears in that person's conversation.
7. **Switch back** to your old messaging app as default. In this app: the Messages tab offers to become default
   again, and campaigns use the Messages-app flow. Nothing in your old app is lost.
8. **Picture message (known gap until Part C):** an incoming MMS only shows a notice in this app.
9. **Reply from the notification** (app closed): pull down the notification, Reply, type, send. It appears in the
   conversation; Mark as read clears the unread count.
10. **New message** to two people (one saved contact, one typed number): each gets their own text.
11. **Campaign label:** after a campaign, its text in a person's conversation shows "Campaign · <name>"; tap it.
12. **Long-press** a message › Delete › Undo; then delete for real. Long-press a conversation › Delete conversation.
13. **Dual SIM:** the SIM chip shows the SIM they texted you on; switch it and send.
14. **Header menu:** Add to contacts, Add to group… from a conversation with an unsaved number.

If anything misbehaves: `adb logcat -s SimBulkSms flutter` while reproducing, and note the step.
