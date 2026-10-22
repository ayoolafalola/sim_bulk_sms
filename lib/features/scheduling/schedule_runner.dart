import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../domain/models/channels.dart';
import '../../domain/models/schedule.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/schedule_calculator.dart';
import '../campaigns/campaign_composer.dart';

class ScheduleRunResult {
  const ScheduleRunResult(this.scheduleId, this.outcome, {this.campaignId, this.campaignName});
  final int scheduleId;
  final ScheduleOutcome outcome;
  /// The campaign to send when [outcome] is `started`.
  final int? campaignId;
  final String? campaignName;
}

/// Decides what happens to schedules that have come due. It never sends:
/// it prepares at most one run per call and the caller starts sending it,
/// so two scheduled sends never overlap (the next one is picked up on a later
/// check, as long as it is still within the grace period).
class ScheduleRunner {
  ScheduleRunner({required this.schedules, required this.campaigns, required this.composer});
  final ScheduleRepository schedules;
  final CampaignRepository campaigns;
  final CampaignComposer composer;

  /// [canAutoSend] is false when this device can't send without the user
  /// (iOS, or Android with sending blocked): the run is prepared and left
  /// ready, and recorded as needing attention.
  Future<List<ScheduleRunResult>> runDue(DateTime now, {required String platform, required bool canAutoSend}) async {
    final out = <ScheduleRunResult>[];
    for (final s in await schedules.due(now)) {
      final decision = dueDecision(s.nextRunAt, now);
      if (decision == DueDecision.notDue) continue;
      if (decision == DueDecision.missed) {
        await schedules.recordRun(s, now: now, outcome: ScheduleOutcome.missed);
        out.add(ScheduleRunResult(s.id, ScheduleOutcome.missed, campaignName: (await campaigns.get(s.campaignId))?.name));
        continue;
      }
      if (await campaigns.anySending()) break; // wait for the current send to finish
      final src = await campaigns.get(s.campaignId);
      if (src == null) continue; // deleted: the schedule cascade-deletes with it

      int? runId;
      ScheduleOutcome outcome;
      // Emails always go by themselves; only texts may need the user.
      final auto = canAutoSend || src.channel == SendChannel.email;
      if (s.kind == ScheduleKind.once) {
        // A one-time schedule sends the campaign itself, exactly as approved.
        if (src.status == CampaignStatus.ready) {
          runId = src.id;
          outcome = auto ? ScheduleOutcome.started : ScheduleOutcome.needsAttention;
        } else {
          outcome = ScheduleOutcome.notReady;
        }
      } else {
        final r = await composer.createScheduledRun(src,
            scheduleId: s.id, label: formatDateTime(s.nextRunAt!), platform: platform);
        runId = r.campaignId;
        outcome = r.blocked
            ? ScheduleOutcome.blocked
            : r.empty
                ? ScheduleOutcome.noRecipients
                : auto ? ScheduleOutcome.started : ScheduleOutcome.needsAttention;
      }
      await schedules.recordRun(s, now: now, outcome: outcome, runCampaignId: runId);
      out.add(ScheduleRunResult(s.id, outcome, campaignId: runId, campaignName: src.name));
      if (runId != null) break; // one run per check
    }
    return out;
  }
}
