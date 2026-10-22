import '../models/schedule.dart';

/// How late a scheduled run may start (phone off, app closed) before it is
/// skipped as missed instead of sent.
const scheduleGracePeriod = Duration(hours: 2);

/// Next local time strictly after [after] at which [spec] should run, or null
/// if it never will again. All times are local wall-clock: "Sunday 08:00"
/// stays 08:00 across daylight-saving changes.
DateTime? nextOccurrence(ScheduleSpec spec, DateTime after) {
  switch (spec.kind) {
    case ScheduleKind.once:
      final at = spec.runAt!;
      return at.isAfter(after) ? at : null;
    case ScheduleKind.weekly:
      if (spec.weekdays & 0x7f == 0) return null;
      final m = spec.minuteOfDay!;
      final end = spec.endsOn == null ? null : DateTime(spec.endsOn!.year, spec.endsOn!.month, spec.endsOn!.day);
      // 8 days covers "today, but the time already passed" -> same weekday next week.
      for (var d = 0; d <= 7; d++) {
        final day = DateTime(after.year, after.month, after.day + d);
        if (end != null && day.isAfter(end)) return null;
        if (spec.weekdays & CampaignSchedule.bit(day.weekday) == 0) continue;
        final at = DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
        if (at.isAfter(after)) return at;
      }
      return null;
  }
}

enum DueDecision { notDue, run, missed }

/// Whether a schedule whose next run is [nextRunAt] should run at [now].
DueDecision dueDecision(DateTime? nextRunAt, DateTime now, {Duration grace = scheduleGracePeriod}) {
  if (nextRunAt == null || nextRunAt.isAfter(now)) return DueDecision.notDue;
  return now.difference(nextRunAt) <= grace ? DueDecision.run : DueDecision.missed;
}

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _two(int n) => n.toString().padLeft(2, '0');
String formatTime(int minuteOfDay) => '${_two(minuteOfDay ~/ 60)}:${_two(minuteOfDay % 60)}';
String formatDateTime(DateTime t) =>
    '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]} ${t.year}, ${_two(t.hour)}:${_two(t.minute)}';
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// e.g. "Every Sun at 08:00" / "Every Mon, Wed, Fri at 18:00 until 31 Dec 2026".
String describeSchedule(ScheduleSpec s) {
  if (s.kind == ScheduleKind.once) return 'Once on ${formatDateTime(s.runAt!)}';
  final days = [for (var w = 1; w <= 7; w++) if (s.weekdays & CampaignSchedule.bit(w) != 0) _days[w - 1]];
  final which = days.length == 7 ? 'Every day' : 'Every ${days.join(', ')}';
  final until = s.endsOn == null ? '' : ' until ${s.endsOn!.day} ${_months[s.endsOn!.month - 1]} ${s.endsOn!.year}';
  return '$which at ${formatTime(s.minuteOfDay!)}$until';
}

ScheduleSpec specOf(CampaignSchedule s) => s.kind == ScheduleKind.once
    ? ScheduleSpec.once(s.runAt!)
    : ScheduleSpec.weekly(weekdays: s.weekdays, minuteOfDay: s.minuteOfDay!, endsOn: s.endsOn);
