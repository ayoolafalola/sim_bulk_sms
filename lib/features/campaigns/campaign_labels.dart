import '../../domain/models/campaign.dart';
import '../../domain/models/schedule.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/send_limits.dart';
import '../common/ui.dart';

/// User-facing wording. `sent` means handed to the carrier (or to Messages on
/// iOS), never "delivered".
String recipientStatusLabel(RecipientStatus s) => switch (s) {
      RecipientStatus.pending => 'Waiting',
      RecipientStatus.prepared => 'Preparing',
      RecipientStatus.awaitingUserAction => 'Waiting for you',
      RecipientStatus.submitted => 'Sending',
      RecipientStatus.sent => 'Sent',
      RecipientStatus.delivered => 'Delivered',
      RecipientStatus.failed => 'Failed',
      RecipientStatus.cancelled => 'Cancelled',
      RecipientStatus.unknown => 'Unknown',
    };

String campaignStatusLabel(CampaignStatus s) => switch (s) {
      CampaignStatus.draft => 'Draft',
      CampaignStatus.ready => 'Ready to send',
      CampaignStatus.running => 'Sending',
      CampaignStatus.awaitingUserAction => 'Waiting for you',
      CampaignStatus.paused => 'Paused',
      CampaignStatus.completed => 'Completed',
      CampaignStatus.partiallyCompleted => 'Partly completed',
      CampaignStatus.failed => 'Failed',
      CampaignStatus.cancelled => 'Cancelled',
    };

String scheduleOutcomeLabel(ScheduleOutcome o) => switch (o) {
      ScheduleOutcome.started => 'Sent automatically',
      ScheduleOutcome.needsAttention => 'Prepared, needs you to send',
      ScheduleOutcome.missed => 'Skipped: more than 2 hours late',
      ScheduleOutcome.blocked => 'Not sent: missing values in the message',
      ScheduleOutcome.noRecipients => 'Not sent: no one to send to',
      ScheduleOutcome.notReady => 'Not sent: campaign was no longer ready',
      ScheduleOutcome.needsPro => 'Not sent: the free app runs 1 schedule (Pro runs them all)',
    };

String limitLabel(LimitKind k, {bool email = false}) =>
    '${k == LimitKind.hourly ? 'Hourly' : 'Daily'} ${email ? 'email ' : ''}limit';

/// "14:32" today, otherwise "Thu 09:10".
String formatWhen(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final sameDay = t.year == n.year && t.month == n.month && t.day == n.day;
  return sameDay ? hm : '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1]} $hm';
}

/// Why a paused campaign is paused, for the campaign screen. Null if paused by you.
String? pausedReasonText(Campaign c, {DateTime? now}) {
  if (c.status != CampaignStatus.paused || c.resumeAt == null) return null;
  final r = c.pausedReason ?? '';
  final which = limitLabel(r.endsWith('hourly_limit') ? LimitKind.hourly : LimitKind.daily, email: r.startsWith('email_'));
  return '$which reached. Resumes automatically at ${formatWhen(c.resumeAt!, now: now)}.';
}

/// Tag colour for a campaign status (the label text always says it too).
Tone campaignTone(CampaignStatus s) => switch (s) {
      CampaignStatus.completed => Tone.success,
      CampaignStatus.running || CampaignStatus.awaitingUserAction || CampaignStatus.paused => Tone.warn,
      CampaignStatus.failed || CampaignStatus.partiallyCompleted => Tone.danger,
      CampaignStatus.ready => Tone.info,
      _ => Tone.neutral,
    };
