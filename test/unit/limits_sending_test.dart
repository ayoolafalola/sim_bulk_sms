import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/background/background_host.dart';
import 'package:sim_bulk_sms/background/background_job.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/attempt_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/schedule_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/send_settings.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/domain/services/send_limits.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_composer.dart';
import 'package:sim_bulk_sms/features/scheduling/next_wake.dart';
import 'package:sim_bulk_sms/features/scheduling/schedule_runner.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

class FakeSms implements SmsCapabilityService {
  final controller = StreamController<SmsEvent>.broadcast();
  final sentTo = <String>[];
  @override Future<SmsCapabilities> getCapabilities() async => androidOk;
  @override Future<bool> requestRequiredPermissions() async => true;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => controller.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async {
    sentTo.add(r.phoneE164);
    controller.add(SmsEvent(type: 'sendSucceeded', campaignRecipientId: r.campaignRecipientId, attemptId: r.attemptId));
    return const SmsOperationResult(RecipientStatus.submitted);
  }
}

class FakeHost implements BackgroundHost {
  final queue = <BackgroundJobRequest>[];
  final results = <String>[];
  final wakes = <DateTime?>[];
  @override Future<BackgroundJobRequest?> takeJob() async => queue.isEmpty ? null : queue.removeAt(0);
  @override Future<void> progress({required String title, String? text, int done = 0, int total = 0}) async {}
  @override Future<void> notifyResult(String title, String text) async => results.add('$title — $text');
  @override Future<bool> scheduleWake(DateTime? at) async { wakes.add(at); return true; }
  @override Future<bool> finish() async => true;
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late CampaignRepository campaigns;
  late AttemptRepository attempts;
  late SettingsRepository settings;
  late FakeSms sms;
  final sleeps = <Duration>[];

  SendOrchestrator orchestrator() => SendOrchestrator(
      sms: sms, attempts: attempts, campaigns: campaigns, settings: settings, sleep: (d) async => sleeps.add(d))
    ..start();

  Future<int> campaign(int n) async {
    final id = await campaigns.createDraft(name: 'Big', template: 'x', platform: 'android');
    await campaigns.saveSnapshot(id, [
      for (var i = 1; i <= n; i++) SnapshotRecipient(name: 'R$i', phoneE164: '+100$i', renderedMessage: 'x'),
    ]);
    return id;
  }

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    campaigns = CampaignRepository(db);
    attempts = AttemptRepository(db);
    settings = SettingsRepository(db);
    sms = FakeSms();
    sleeps.clear();
  });
  tearDown(() => db.close());

  test('settings round-trip and defaults', () async {
    expect((await settings.load()).delaySeconds, 3);
    await settings.save(const SendSettings(delaySeconds: 7, hourlyLimit: 0, dailyLimit: 50, defaultRegion: 'GH'));
    final s = await settings.load();
    expect((s.delaySeconds, s.hourlyLimit, s.dailyLimit, s.defaultRegion), (7, 0, 50, 'GH'));
  });

  test('uses the configured delay between messages', () async {
    await settings.save(const SendSettings(delaySeconds: 5, hourlyLimit: 0, dailyLimit: 0));
    await orchestrator().runAndroid(await campaign(3));
    expect(sleeps, everyElement(const Duration(seconds: 5)));
    expect(sms.sentTo, hasLength(3));
  });

  test('hourly limit: sends up to the limit, then pauses with a resume time', () async {
    await settings.save(const SendSettings(delaySeconds: 1, hourlyLimit: 2, dailyLimit: 0));
    final id = await campaign(5);
    final before = DateTime.now();
    final hit = await orchestrator().runAndroid(id);
    expect(sms.sentTo, hasLength(2));
    expect(hit!.kind, LimitKind.hourly);
    final c = (await campaigns.get(id))!;
    expect(c.status, CampaignStatus.paused);
    expect(c.pausedReason, 'hourly_limit');
    expect(c.resumeAt!.difference(before).inMinutes, inInclusiveRange(59, 60));
    expect((await campaigns.statusCounts(id))[RecipientStatus.pending], 3);
    expect(await campaigns.nextResume(), isNotNull);
    expect(await campaigns.dueResumes(DateTime.now()), isEmpty);
    expect(await campaigns.dueResumes(c.resumeAt!), [id]);
  });

  test('starting while at the limit waits and resumes by itself', () async {
    await settings.save(const SendSettings(delaySeconds: 1, hourlyLimit: 1, dailyLimit: 0));
    await orchestrator().runAndroid(await campaign(1)); // uses the hour's only slot
    final b = await campaign(2);
    final hit = await orchestrator().runAndroid(b);
    expect(hit, isNotNull);
    expect(sms.sentTo, hasLength(1));
    final c = (await campaigns.get(b))!;
    expect(c.status, CampaignStatus.paused);
    expect(c.resumeAt, isNotNull);
  });

  test('pausing yourself clears the automatic resume', () async {
    await settings.save(const SendSettings(delaySeconds: 1, hourlyLimit: 1, dailyLimit: 0));
    final id = await campaign(3);
    await orchestrator().runAndroid(id);
    await attempts.markRunning(id); // as if it resumed
    await campaigns.requestPause(id);
    final c = (await campaigns.get(id))!;
    expect(c.pausedReason, 'user');
    expect(c.resumeAt, isNull);
    expect(await campaigns.nextResume(), isNull);
  });

  test('background service resumes a limit-paused campaign when its time comes, and wakes up for it', () async {
    await settings.save(const SendSettings(delaySeconds: 1, hourlyLimit: 0, dailyLimit: 0));
    final id = await campaign(2);
    await attempts.markRunning(id);
    final resumeAt = DateTime.now().subtract(const Duration(minutes: 1));
    await campaigns.pauseForLimit(id, LimitKind.daily, resumeAt);
    final schedules = ScheduleRepository(db);
    expect(await nextWakeUp(schedules, campaigns), isNotNull);

    final host = FakeHost()..queue.add(const BackgroundJobRequest.check());
    final composer = CampaignComposer(contacts: ContactRepository(db), groups: GroupRepository(db), campaigns: campaigns);
    await BackgroundJob(
      host: host, sms: sms, orchestrator: orchestrator(), campaigns: campaigns, schedules: schedules,
      runner: ScheduleRunner(schedules: schedules, campaigns: campaigns, composer: composer),
      sleep: (_) async {}, waitForCallbacks: Duration.zero,
    ).run();
    expect(sms.sentTo, hasLength(2));
    expect((await campaigns.get(id))!.status, CampaignStatus.completed);
    expect(host.wakes.last, isNull); // nothing left to wake for
  });

  test('a send that hits the limit is reported with its resume time', () async {
    await settings.save(const SendSettings(delaySeconds: 1, hourlyLimit: 1, dailyLimit: 0));
    final id = await campaign(3);
    final host = FakeHost()..queue.add(BackgroundJobRequest.send(id));
    final schedules = ScheduleRepository(db);
    final composer = CampaignComposer(contacts: ContactRepository(db), groups: GroupRepository(db), campaigns: campaigns);
    await BackgroundJob(
      host: host, sms: sms, orchestrator: orchestrator(), campaigns: campaigns, schedules: schedules,
      runner: ScheduleRunner(schedules: schedules, campaigns: campaigns, composer: composer),
      sleep: (_) async {}, waitForCallbacks: Duration.zero,
    ).run();
    expect(host.results.single, startsWith('Big paused — Hourly limit reached. Resumes automatically at '));
    expect(host.wakes.last, (await campaigns.get(id))!.resumeAt);
  });
}
