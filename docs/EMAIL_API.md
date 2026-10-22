# Campaign email: the Mailgun-compatible API

Settings › Email › **Mailgun API** sends each campaign email with one HTTPS request. It works with Mailgun and
with any service that copies Mailgun's "send message" API: change the **API base URL**.

## Settings

| Field | Example | Notes |
| --- | --- | --- |
| API base URL | `https://api.mailgun.net/v3` | EU accounts: `https://api.eu.mailgun.net/v3`. Must be `https://`. |
| Sending domain | `mg.example.com` | The domain verified with your provider (SPF/DKIM set up there). |
| API key | `key-…` | Your provider's private/sending API key. Stored only in the app's private storage on this phone. |
| From name / address | `Grace Church` / `news@mg.example.com` | Replies go to this address. |
| Limits | 50 per hour, 400 per day | Separate from the SMS limits; 0 = no limit. |
| Unsubscribe line | on | Added to the end of every email, plus a `List-Unsubscribe` header. |

Use **Send test email** after saving; it sends one real email.

## The request

```
POST {base}/{domain}/messages
Authorization: Basic base64("api:" + API key)
Content-Type: application/x-www-form-urlencoded
Accept: application/json
```

Form fields:

| Field | Value |
| --- | --- |
| `from` | `"From name" <from address>` |
| `to` | `"Ada Okafor" <ada@example.com>` |
| `subject` | the campaign subject with placeholders filled in |
| `text` | the message, plus the unsubscribe line |
| `html` | the same text as simple HTML |
| `v:campaign_id` | the app's campaign id |
| `v:message_id` | unique per attempt, e.g. `cr-412-a977` (use it to ignore duplicates in webhooks) |
| `h:List-Unsubscribe` | `<mailto:from address?subject=unsubscribe>` (when the unsubscribe line is on) |

## How answers are recorded

| Answer | Status in the app | Retried automatically? |
| --- | --- | --- |
| 2xx | **Sent**; the JSON `id` is stored | – |
| 401 / 403 | **Failed** ("check the API key"); the campaign **pauses** | No |
| 404 | **Failed** ("check the base URL and domain"); the campaign **pauses** | No |
| 400, 429, other 4xx | **Failed** with the provider's `message` | No (Send again from the campaign) |
| 5xx, timeout, connection lost after sending | **Unknown**: it may have arrived | Never; "Send again (may duplicate)" asks first |
| No connection at all | **Failed** (nothing left the phone) | No |

Emails get no delivery reports in the app; "Sent" means your provider accepted it.

## Building your own compatible endpoint

Accept the form above at `POST /{domain}/messages`, check the Basic auth password, and answer `200` with
`{"id": "<your message id>", "message": "Queued"}`. Answer 4xx for anything you will never send and 5xx only
when you are unsure; the app treats 5xx as "may have been sent". Use `v:message_id` to drop duplicates.
