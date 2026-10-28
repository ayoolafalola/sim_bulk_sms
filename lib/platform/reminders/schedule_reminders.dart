import 'package:flutter/services.dart';
import '../../app/app_info.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../domain/models/birthday_settings.dart';
import '../../domain/services/schedule_calculator.dart';
import '../../features/birthdays/birthday_runner.dart';

/// A local notification at the time a scheduled campaign is due.
class Reminder {
  const Reminder({required this.id, required this.at, required this.title, required this.body});
  final String id;
  final DateTime at;
  final String title, body;
}

/// Where texts can't be sent in the background (iPhone, iPad), scheduled campaigns remind you instead.
abstract class ScheduleReminders {
  Future<bool> requestPermission();
  /// Replaces every scheduled-campaign reminder with [reminders].
  Future<void> set(List<Reminder> reminders);
}

class IosScheduleReminders implements ScheduleReminders {
  static const _ch = MethodChannel('app.sim_bulk_sms/sms_methods');
  @override
  Future<bool> requestPermission() async => await _ch.invokeMethod<bool>('requestReminderPermission') ?? false;
  @override
  Future<void> set(List<Reminder> reminders) => _ch.invokeMethod('setReminders', [
        for (final r in reminders)
          {'id': r.id, 'at': r.at.millisecondsSinceEpoch, 'title': r.title, 'body': r.body},
      ]);
}

/// The next runs of each enabled schedule, soonest first: up to [perSchedule] each (so weekly schedules keep
/// reminding even if the app isn't opened in between) and [max] in all (iOS keeps 64 pending).
List<Reminder> remindersFor(List<ScheduleListItem> schedules, DateTime now, {int perSchedule = 8, int max = 60}) {
  final out = <Reminder>[];
  for (final item in schedules) {
    final s = item.schedule;
    if (!s.enabled || s.nextRunAt == null) continue;
    final spec = specOf(s);
    var at = s.nextRunAt!.isAfter(now) ? s.nextRunAt : nextOccurrence(spec, now);
    for (var i = 0; i < perSchedule && at != null; i++) {
      out.add(Reminder(
        id: '${s.id}-${at.millisecondsSinceEpoch}', at: at,
        title: '${item.campaignName} is due',
        body: 'Open $appName to send it. Texts need a tap each; emails go by themselves.',
      ));
      at = nextOccurrence(spec, at);
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.take(max).toList();
}

/// Birthday wishes: one reminder on each day with birthdays, at the chosen time (today's only if it
/// hasn't run yet). [upcoming] comes from [BirthdayRunner.upcoming].
List<Reminder> birthdayReminders(List<UpcomingBirthday> upcoming, BirthdaySettings s, DateTime now) {
  final byDay = <String, List<UpcomingBirthday>>{};
  for (final u in upcoming) {
    byDay.putIfAbsent(dayKey(u.on), () => []).add(u);
  }
  return [
    for (final e in byDay.entries)
      if (DateTime(e.value.first.on.year, e.value.first.on.month, e.value.first.on.day, s.minuteOfDay ~/ 60,
              s.minuteOfDay % 60)
          case final at when at.isAfter(now) && !(e.key == dayKey(now) && s.lastRunDate == e.key))
        Reminder(
          id: 'bday-${e.key}', at: at,
          title: e.value.length == 1 ? '${e.value.first.contact.name}\'s birthday is today' : '${e.value.length} birthdays today',
          body: 'Open $appName to send your birthday wishes. Emails go by themselves.',
        ),
  ];
}
