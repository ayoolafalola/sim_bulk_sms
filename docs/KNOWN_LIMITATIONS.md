# Known limitations
- iOS cannot send silently or in the background; every message needs a user tap.
- Android direct send is blocked from Play distribution until the SMS permission policy is resolved.
- Delivery reports depend on the carrier; absence does not mean failure.
- SIM subscription ids are device-local; phone numbers of SIMs are not read.
- Segment counts are estimates, not carrier billing.
- Entire codebase is unbuilt and untested (see README).
