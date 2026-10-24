import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/repositories/schedule_repository.dart';
import 'package:sim_bulk_sms/domain/models/schedule.dart';
import 'package:sim_bulk_sms/platform/reminders/schedule_reminders.dart';

CampaignSchedule weekly(int id, {bool enabled = true}) => CampaignSchedule(
      id: id, campaignId: id, kind: ScheduleKind.weekly, enabled: enabled,
      weekdays: CampaignSchedule.bit(DateTime.saturday) | CampaignSchedule.bit(DateTime.sunday), minuteOfDay: 8 * 60,
      nextRunAt: DateTime(2026, 10, 24, 8),
    );

void main() {
  final now = DateTime(2026, 10, 24, 7); // Saturday 07:00

  test('upcoming runs of each enabled schedule, soonest first', () {
    final r = remindersFor([ScheduleListItem(weekly(1), 'Sunday service')], now, perSchedule: 4);
    expect(r.map((x) => x.at), [
      DateTime(2026, 10, 24, 8), DateTime(2026, 10, 25, 8), DateTime(2026, 10, 31, 8), DateTime(2026, 11, 1, 8),
    ]);
    expect(r.first.title, 'Sunday service is due');
    expect(r.map((x) => x.id).toSet(), hasLength(4)); // unique ids
  });

  test('paused schedules and finished one-time schedules get no reminder; the total is capped', () {
    final once = CampaignSchedule(id: 3, campaignId: 3, kind: ScheduleKind.once, enabled: true,
        runAt: DateTime(2026, 10, 1), nextRunAt: null);
    final many = [for (var i = 10; i < 30; i++) ScheduleListItem(weekly(i), 'C$i')];
    expect(remindersFor([ScheduleListItem(weekly(2, enabled: false), 'Paused'), ScheduleListItem(once, 'Done')], now),
        isEmpty);
    expect(remindersFor(many, now), hasLength(60)); // iOS keeps at most 64 pending
  });
}
