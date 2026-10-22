import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/domain/models/schedule.dart';
import 'package:sim_bulk_sms/domain/services/schedule_calculator.dart';

int days(List<int> weekdays) => weekdays.fold(0, (m, d) => m | CampaignSchedule.bit(d));

void main() {
  // 2026-10-21 is a Wednesday.
  final wedNoon = DateTime(2026, 10, 21, 12);

  group('weekly', () {
    final sun8 = ScheduleSpec.weekly(weekdays: days([DateTime.sunday]), minuteOfDay: 8 * 60);
    test('next Sunday 08:00', () => expect(nextOccurrence(sun8, wedNoon), DateTime(2026, 10, 25, 8)));
    test('same day, time not yet reached -> today',
        () => expect(nextOccurrence(sun8, DateTime(2026, 10, 25, 7, 59)), DateTime(2026, 10, 25, 8)));
    test('same day, exactly at or after the time -> next week', () {
      expect(nextOccurrence(sun8, DateTime(2026, 10, 25, 8)), DateTime(2026, 11, 1, 8));
      expect(nextOccurrence(sun8, DateTime(2026, 10, 25, 9)), DateTime(2026, 11, 1, 8));
    });
    test('several days: picks the soonest', () {
      final s = ScheduleSpec.weekly(weekdays: days([DateTime.monday, DateTime.friday]), minuteOfDay: 18 * 60);
      expect(nextOccurrence(s, wedNoon), DateTime(2026, 10, 23, 18));
      expect(nextOccurrence(s, DateTime(2026, 10, 23, 18, 1)), DateTime(2026, 10, 26, 18));
    });
    test('end date is inclusive, then stops', () {
      final s = ScheduleSpec.weekly(weekdays: days([DateTime.sunday]), minuteOfDay: 480, endsOn: DateTime(2026, 11, 1));
      expect(nextOccurrence(s, wedNoon), DateTime(2026, 10, 25, 8));
      expect(nextOccurrence(s, DateTime(2026, 10, 25, 9)), DateTime(2026, 11, 1, 8));
      expect(nextOccurrence(s, DateTime(2026, 11, 1, 9)), isNull);
    });
    test('no days selected never runs',
        () => expect(nextOccurrence(const ScheduleSpec.weekly(weekdays: 0, minuteOfDay: 480), wedNoon), isNull));
    test('crosses month and year ends', () {
      final s = ScheduleSpec.weekly(weekdays: days([DateTime.friday]), minuteOfDay: 60);
      expect(nextOccurrence(s, DateTime(2026, 12, 31, 12)), DateTime(2027, 1, 1, 1));
    });
  });

  group('once', () {
    final at = DateTime(2026, 10, 22, 9, 30);
    test('future time is the next run', () => expect(nextOccurrence(ScheduleSpec.once(at), wedNoon), at));
    test('past time never runs', () => expect(nextOccurrence(ScheduleSpec.once(at), DateTime(2026, 10, 22, 9, 30)), isNull));
  });

  group('dueDecision (2 hour grace)', () {
    final due = DateTime(2026, 10, 25, 8);
    test('before: not due', () => expect(dueDecision(due, DateTime(2026, 10, 25, 7, 59)), DueDecision.notDue));
    test('on time: run', () => expect(dueDecision(due, due), DueDecision.run));
    test('2 hours late: still run', () => expect(dueDecision(due, DateTime(2026, 10, 25, 10)), DueDecision.run));
    test('later: missed', () => expect(dueDecision(due, DateTime(2026, 10, 25, 10, 1)), DueDecision.missed));
    test('nothing scheduled', () => expect(dueDecision(null, due), DueDecision.notDue));
  });

  test('describe', () {
    expect(describeSchedule(ScheduleSpec.weekly(weekdays: days([DateTime.sunday]), minuteOfDay: 480)), 'Every Sun at 08:00');
    expect(describeSchedule(ScheduleSpec.weekly(weekdays: days([1, 3, 5]), minuteOfDay: 1080, endsOn: DateTime(2026, 12, 31))),
        'Every Mon, Wed, Fri at 18:00 until 31 Dec 2026');
    expect(describeSchedule(ScheduleSpec.once(DateTime(2026, 10, 25, 8))), 'Once on Sun 25 Oct 2026, 08:00');
  });
}
