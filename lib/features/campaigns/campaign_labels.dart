import '../../domain/models/schedule.dart';
import '../../domain/models/statuses.dart';

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
    };
