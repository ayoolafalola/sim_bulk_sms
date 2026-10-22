import '../models/send_settings.dart';

enum LimitKind { hourly, daily }

/// Sending must wait: which limit, and when the next message may go.
class LimitHit {
  const LimitHit(this.kind, this.resumeAt);
  final LimitKind kind;
  final DateTime resumeAt;
}

const _hour = Duration(hours: 1), _day = Duration(hours: 24);

/// Whether one more message may be sent at [now], given the send times of the
/// last 24 hours ([sent], any order). Rolling windows: a limit of L means at
/// most L messages in any 60 minutes / 24 hours. Returns null when allowed.
LimitHit? checkLimits({required List<DateTime> sent, required DateTime now, required SendSettings settings}) {
  final sorted = [...sent]..sort();
  LimitHit? hit;
  for (final (kind, limit, window) in [
    (LimitKind.daily, settings.dailyLimit, _day),
    (LimitKind.hourly, settings.hourlyLimit, _hour),
  ]) {
    if (limit <= 0) continue;
    final inWindow = sorted.where((t) => now.difference(t) < window).toList();
    if (inWindow.length < limit) continue;
    // The send that must leave the window before there's room for one more.
    final resumeAt = inWindow[inWindow.length - limit].add(window);
    if (hit == null || resumeAt.isAfter(hit.resumeAt)) hit = LimitHit(kind, resumeAt);
  }
  return hit;
}

/// When sending [messages] more would finish if started at [now], honoring the
/// delay and both limits. Simulates the sender; [sent] as in [checkLimits].
DateTime estimateFinish({
  required int messages, required SendSettings settings, required List<DateTime> sent, required DateTime now,
}) {
  final times = [...sent]..sort();
  var t = now;
  for (var i = 0; i < messages; i++) {
    // Keep only what can still matter (last 24 h relative to t).
    while (times.isNotEmpty && t.difference(times.first) >= _day) {
      times.removeAt(0);
    }
    final hit = checkLimits(sent: times, now: t, settings: settings);
    if (hit != null) {
      t = hit.resumeAt;
      i--; // retry this message at the resume time
      continue;
    }
    times.add(t);
    if (i < messages - 1) t = t.add(settings.delay);
  }
  return t;
}

String formatDuration(Duration d) {
  if (d.inMinutes < 1) return 'less than a minute';
  if (d.inHours < 1) return '${d.inMinutes} min';
  final h = d.inHours, m = d.inMinutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}
