# Known limitations
- iOS cannot send silently or in the background; every message needs a user tap.
- Android direct send is blocked from Play distribution until the SMS permission policy is resolved.
- Delivery reports depend on the carrier; absence does not mean failure.
- SIM subscription ids are device-local; phone numbers of SIMs are not read.
- Segment counts are estimates, not carrier billing.
- Kotlin and Swift bridges have never been compiled or run on a device.
- Android composer fallback (system messaging handoff when direct sending is disabled) is not implemented yet.
- If the process dies while Android callbacks are pending, those messages become `unknown` even if the carrier sent them.
- No UI screens exist yet; the send queue is exercised only through unit tests with a fake SMS service.
