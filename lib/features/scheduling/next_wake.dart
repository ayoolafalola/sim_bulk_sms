import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../birthdays/birthday_runner.dart';

/// When the background service next needs to run: the earliest scheduled run,
/// automatic resume after a send limit, or birthday wishes, whichever comes first.
Future<DateTime?> nextWakeUp(ScheduleRepository schedules, CampaignRepository campaigns,
    {BirthdayRunner? birthdays, DateTime? now}) async {
  final times = [
    await schedules.nextWake(),
    await campaigns.nextResume(),
    await birthdays?.nextRunAt(now ?? DateTime.now()),
  ].whereType<DateTime>().toList()
    ..sort();
  return times.firstOrNull;
}
