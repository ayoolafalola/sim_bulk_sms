import '../models/statuses.dart';

/// Derives the final campaign status from per-recipient counts, or null while
/// work is still in flight. `sent` counts as success here (delivery reports are
/// carrier-dependent). Unconfirmed `unknown` outcomes are never reported as
/// "failed": a campaign with no confirmed sends but unknowns is partial.
CampaignStatus? computeCampaignOutcome(Map<RecipientStatus, int> c) {
  int n(RecipientStatus s) => c[s] ?? 0;
  final total = c.values.fold<int>(0, (a, b) => a + b);
  if (total == 0) return null;
  final inFlight = n(RecipientStatus.pending) + n(RecipientStatus.prepared) +
      n(RecipientStatus.submitted) + n(RecipientStatus.awaitingUserAction);
  if (inFlight > 0) return null;
  final ok = n(RecipientStatus.sent) + n(RecipientStatus.delivered);
  if (ok == total) return CampaignStatus.completed;
  if (n(RecipientStatus.cancelled) == total) return CampaignStatus.cancelled;
  if (ok == 0 && n(RecipientStatus.unknown) == 0) return CampaignStatus.failed;
  return CampaignStatus.partiallyCompleted;
}
