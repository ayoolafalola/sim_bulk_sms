import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/schedule_repository.dart';

/// When the background service next needs to run: the earliest scheduled run
/// or automatic resume after a send limit, whichever comes first.
Future<DateTime?> nextWakeUp(ScheduleRepository schedules, CampaignRepository campaigns) async {
  final a = await schedules.nextWake();
  final b = await campaigns.nextResume();
  if (a == null) return b;
  if (b == null) return a;
  return a.isBefore(b) ? a : b;
}
