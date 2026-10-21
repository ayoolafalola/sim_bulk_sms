# SMS state machine
Android: pending -> prepared -> submitted (API accepted) -> sent (all parts RESULT_OK) -> delivered (all parts' delivery reports). Any part failure -> failed.
iOS: pending -> prepared -> awaiting_user_action -> sent (composer "sent": queued by iOS, not delivery) | cancelled | failed.
Recovery: after process death, prepared/submitted/awaiting_user_action become `unknown` and are never auto-retried; the user decides. Late/duplicate callbacks are ignored by `RecipientStateMachine.applyOrIgnore`. In-memory aggregation in `SmsBridge` is lost on process death; Dart must persist the attempt row before invoking native send.
