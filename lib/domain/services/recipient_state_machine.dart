import '../models/statuses.dart';

/// Allowed transitions between recipient statuses. See docs/SMS_STATE_MACHINE.md.
/// Any transition not listed is rejected, which also makes duplicate/late
/// callbacks harmless (see [applyOrIgnore]).
class RecipientStateMachine {
  static const Map<RecipientStatus, Set<RecipientStatus>> _allowed = {
    RecipientStatus.pending: {RecipientStatus.prepared, RecipientStatus.cancelled},
    RecipientStatus.prepared: {
      RecipientStatus.submitted, RecipientStatus.awaitingUserAction,
      RecipientStatus.failed, RecipientStatus.cancelled, RecipientStatus.unknown,
    },
    RecipientStatus.awaitingUserAction: {
      RecipientStatus.sent, RecipientStatus.cancelled, RecipientStatus.failed, RecipientStatus.unknown,
    },
    RecipientStatus.submitted: {
      RecipientStatus.sent, RecipientStatus.failed, RecipientStatus.unknown,
    },
    RecipientStatus.sent: {RecipientStatus.delivered, RecipientStatus.failed, RecipientStatus.unknown},
    // Operator-side delivery failure can follow a "sent" callback; unknown can be resolved manually.
    RecipientStatus.unknown: {
      RecipientStatus.sent, RecipientStatus.delivered, RecipientStatus.failed, RecipientStatus.cancelled,
    },
    RecipientStatus.delivered: {},
    // Explicit user-initiated retry only: re-queue to `pending`.
    RecipientStatus.failed: {RecipientStatus.pending},
    RecipientStatus.cancelled: {RecipientStatus.pending},
  };

  static bool canTransition(RecipientStatus from, RecipientStatus to) =>
      _allowed[from]?.contains(to) ?? false;

  /// Returns the new status, or [current] if the transition is invalid/duplicate.
  static RecipientStatus applyOrIgnore(RecipientStatus current, RecipientStatus next) =>
      canTransition(current, next) ? next : current;

  /// After process death, anything in flight has an uncertain outcome.
  static RecipientStatus recoverAfterInterruption(RecipientStatus s) =>
      s == RecipientStatus.prepared ||
              s == RecipientStatus.submitted ||
              s == RecipientStatus.awaitingUserAction
          ? RecipientStatus.unknown
          : s;
}
