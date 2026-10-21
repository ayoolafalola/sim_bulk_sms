# SMS state machine

Android: pending -> prepared -> submitted (API accepted) -> sent (all parts RESULT_OK) -> delivered (all parts' delivery reports). Any part failure -> failed.
iOS: pending -> prepared -> awaiting_user_action -> sent (composer "sent": queued by iOS, not delivery) | cancelled | failed.

Late/duplicate callbacks are ignored by `RecipientStateMachine`. In-memory aggregation in `SmsBridge` is lost on process death; Dart persists the attempt row before invoking native send.

## Implemented queue rules (Phase 4b)
- Order of operations (Android): `beginAttempt` (row persisted, recipient `prepared`) -> mark `submitted` -> native send -> callbacks (`sent`/`failed`/`delivered`). A crash between steps leaves `submitted`, recovered as `unknown`.
- `AttemptRepository.recoverInterrupted()` must run at app start; it moves in-flight recipients to `unknown` and pauses running campaigns. `unknown` is never retried automatically.
- Retrying `failed`/`cancelled` is a user action (re-queue to `pending`); retrying `unknown` requires acknowledging possible duplicate delivery. `delivered` can never be re-queued.
- `subscription_unavailable` / `permission_denied` halt the run and pause the campaign; the app never switches SIM on its own.
- iOS: one composer per call; cancel -> `cancelled`; composer "sent" -> `sent`. The campaign stays `awaiting_user_action` until every recipient is settled.
- Campaign outcome: all sent/delivered -> completed; all cancelled -> cancelled; no confirmed sends and no unknowns -> failed; anything else settled -> partially_completed. Unknown outcomes are never reported as failed.
