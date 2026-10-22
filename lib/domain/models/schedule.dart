enum ScheduleKind { once, weekly }

/// What happened the last time a schedule came due.
enum ScheduleOutcome {
  started,        // a run campaign was created and sending started (or handed to you on iOS)
  needsAttention, // run created but this device can't send right now (see the campaign)
  missed,         // came due more than the grace period ago (phone off/app closed): skipped
  blocked,        // message has unresolved variables: nothing sent
  noRecipients,   // nobody eligible at run time
  notReady,       // one-time schedule, but the campaign was no longer ready
  needsPro,       // free plan: only the first schedule runs
}

class CampaignSchedule {
  const CampaignSchedule({
    required this.id, required this.campaignId, required this.kind, this.runAt,
    this.weekdays = 0, this.minuteOfDay, this.endsOn, required this.enabled, this.nextRunAt,
    this.lastRunAt, this.lastRunCampaignId, this.lastOutcome,
  });
  final int id, campaignId;
  final ScheduleKind kind;
  final DateTime? runAt;        // once (local)
  final int weekdays;           // weekly bitmask, Monday = 1 << 0 ... Sunday = 1 << 6
  final int? minuteOfDay;       // weekly local time
  final DateTime? endsOn;       // weekly last date, inclusive (local date)
  final bool enabled;
  final DateTime? nextRunAt;    // local
  final DateTime? lastRunAt;
  final int? lastRunCampaignId;
  final ScheduleOutcome? lastOutcome;

  static int bit(int weekday) => 1 << (weekday - 1); // DateTime.monday == 1
  bool runsOn(int weekday) => weekdays & bit(weekday) != 0;
}

/// Input for creating/replacing a schedule.
class ScheduleSpec {
  const ScheduleSpec.once(DateTime this.runAt)
      : kind = ScheduleKind.once, weekdays = 0, minuteOfDay = null, endsOn = null;
  const ScheduleSpec.weekly({required this.weekdays, required int this.minuteOfDay, this.endsOn})
      : kind = ScheduleKind.weekly, runAt = null;
  final ScheduleKind kind;
  final DateTime? runAt;
  final int weekdays;
  final int? minuteOfDay;
  final DateTime? endsOn;
}
