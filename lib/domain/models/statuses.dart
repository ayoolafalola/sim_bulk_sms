/// Per-recipient status (FR-11). `sent` != `delivered`.
enum RecipientStatus {
  pending, prepared, awaitingUserAction, submitted, sent, delivered, failed, cancelled, unknown;

  bool get isTerminal => const {delivered, failed, cancelled}.contains(this);
  /// Statuses that may already have reached the carrier; never auto-retry these.
  bool get mayHaveBeenSent => const {submitted, sent, delivered, unknown}.contains(this);
}

enum CampaignStatus {
  draft, ready, running, awaitingUserAction, paused, completed, partiallyCompleted, failed, cancelled
}

enum ConsentStatus { unknown, optedIn, optedOut }
