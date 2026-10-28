import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../data/database/app_database.dart';
import '../data/repositories/attempt_repository.dart';
import '../data/repositories/campaign_repository.dart';
import '../data/repositories/contact_repository.dart';
import '../data/repositories/group_repository.dart';
import '../data/repositories/schedule_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../features/birthdays/birthday_runner.dart';
import '../features/campaigns/campaign_composer.dart';
import '../features/scheduling/schedule_runner.dart';
import '../features/sms_sending/send_orchestrator.dart';
import '../platform/email/email_senders.dart';
import '../platform/email/google_gmail_auth.dart';
import '../platform/sms/android_sms_service.dart';
import 'background_host.dart';
import 'background_job.dart';

/// Entry point of the headless engine started by the Android `SendService`.
/// No UI: it works through the service's queue and then asks it to stop.
@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final host = NativeBackgroundHost();
  try {
    final db = await openAppDatabase(databaseFactory, p.join(await getDatabasesPath(), 'sim_bulk_sms.db'));
    final attempts = AttemptRepository(db);
    // The service is the only Android sender and has just started, so anything
    // still in flight belongs to a process that died: mark it unknown.
    await attempts.recoverInterrupted();
    final campaigns = CampaignRepository(db);
    final schedules = ScheduleRepository(db);
    final sms = AndroidSmsService();
    final settings = SettingsRepository(db);
    final gmail = GoogleGmailAuth();
    final orchestrator = SendOrchestrator(
      sms: sms, attempts: attempts, campaigns: campaigns, settings: settings,
      emailSender: () async => emailSenderFor(await settings.loadEmail(), gmail: gmail),
    )..start();
    final composer = CampaignComposer(
        contacts: ContactRepository(db), groups: GroupRepository(db), campaigns: campaigns, proStatus: settings.loadPro);
    await BackgroundJob(
      host: host, sms: sms, orchestrator: orchestrator, campaigns: campaigns, schedules: schedules,
      runner: ScheduleRunner(schedules: schedules, campaigns: campaigns, composer: composer, proStatus: settings.loadPro),
      birthdays: BirthdayRunner(db: db, settings: settings, contacts: ContactRepository(db), groups: GroupRepository(db),
          campaigns: campaigns),
    ).run();
  } catch (e, st) {
    debugPrint('Background sending failed: $e\n$st');
    await host.notifyResult('Background sending stopped', '$e');
    await host.finish();
  }
}
