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
import 'package:sim_bulk_sms/domain/models/campaign.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/schedule.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_composer.dart';
import 'package:sim_bulk_sms/features/scheduling/schedule_runner.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);
const androidNoPermission = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.permissionDenied,
    messageForUser: 'SMS permission is required to send through your SIM.');

class FakeSms implements SmsCapabilityService {
  FakeSms(this.caps);
  SmsCapabilities caps;
  final controller = StreamController<SmsEvent>.broadcast();
  final sentTo = <String>[];
  bool callbacks = true; // emit sendSucceeded + deliveryReported for each send
  @override Future<SmsCapabilities> getCapabilities() async => caps;
  @override Future<bool> requestRequiredPermissions() async => true;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => controller.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async {
    sentTo.add(r.phoneE164);
    if (callbacks) {
      for (final t in ['sendSucceeded', 'deliveryReported']) {
        controller.add(SmsEvent(type: t, campaignRecipientId: r.campaignRecipientId, attemptId: r.attemptId));
      }
    }
    return const SmsOperationResult(RecipientStatus.submitted);
  }
}

class FakeHost implements BackgroundHost {
  final queue = <BackgroundJobRequest>[];
  final results = <String>[];
  final progressLog = <String>[];
  final wakes = <DateTime?>[];
  /// Jobs to add the first time the service tries to finish (arrived meanwhile).
  List<BackgroundJobRequest> lateJobs = [];
  int finishes = 0;
  @override Future<BackgroundJobRequest?> takeJob() async => queue.isEmpty ? null : queue.removeAt(0);
  @override Future<void> progress({required String title, String? text, int done = 0, int total = 0}) async =>
      progressLog.add('$title: $text');
  @override Future<void> notifyResult(String title, String text) async => results.add('$title — $text');
  @override Future<bool> scheduleWake(DateTime? at) async { wakes.add(at); return true; }
  @override
  Future<bool> finish() async {
    finishes++;
    if (lateJobs.isNotEmpty) { queue.addAll(lateJobs); lateJobs = []; return false; }
    return true;
  }
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late CampaignRepository campaigns;
  late ScheduleRepository schedules;
  late CampaignComposer composer;
  late FakeSms sms;
  late FakeHost host;
  late SendOrchestrator orch;
  late DateTime now;
  late int groupId;

  BackgroundJob job() => BackgroundJob(
        host: host, sms: sms, orchestrator: orch, campaigns: campaigns, schedules: schedules,
        runner: ScheduleRunner(schedules: schedules, campaigns: campaigns, composer: composer),
        clock: () => now,
        sleep: (d) async { now = now.add(d); await Future<void>.delayed(Duration.zero); },
      );

  Future<int> campaign(int people) async {
    final contacts = ContactRepository(db);
    for (var i = 1; i <= people; i++) {
      final id = await contacts.add(Contact(name: 'P$i', phoneRaw: '+10$i', phoneNormalized: '+10$i'));
      await GroupRepository(db).addContacts(groupId, [id]);
    }
    final plan = await composer.plan(template: 'Hi {first_name}', groupIds: {groupId}, contactIds: {});
    return composer.save(name: 'Reminder', template: 'Hi {first_name}', platform: 'android', plan: plan,
        audience: CampaignAudience(groupIds: {groupId}));
  }

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    campaigns = CampaignRepository(db);
    schedules = ScheduleRepository(db);
    composer = CampaignComposer(contacts: ContactRepository(db), groups: GroupRepository(db), campaigns: campaigns);
    sms = FakeSms(androidOk);
    host = FakeHost();
    orch = SendOrchestrator(sms: sms, attempts: AttemptRepository(db), campaigns: campaigns, sleep: (_) async {})..start();
    now = DateTime(2026, 10, 25, 8); // Sunday 08:00
    groupId = await GroupRepository(db).create('G');
  });
  tearDown(() async { await orch.dispose(); await db.close(); });

  test('send job: sends everyone, waits for callbacks, reports, sets next wake-up, finishes', () async {
    final id = await campaign(3);
    await schedules.save(id, ScheduleSpec.weekly(weekdays: CampaignSchedule.bit(DateTime.sunday), minuteOfDay: 480),
        now: now);
    host.queue.add(BackgroundJobRequest.send(id));
    await job().run();
    expect(sms.sentTo, hasLength(3));
    expect(await campaigns.statusCounts(id), {RecipientStatus.delivered: 3});
    expect((await campaigns.get(id))!.status, CampaignStatus.completed);
    expect(host.results.single, 'Reminder finished — 3 delivered');
    expect(host.wakes.last, DateTime(2026, 11, 1, 8));
    expect(host.finishes, 1);
  });

  test('check job: runs a due weekly schedule with the current members', () async {
    final id = await campaign(2);
    await schedules.save(id, ScheduleSpec.weekly(weekdays: CampaignSchedule.bit(DateTime.sunday), minuteOfDay: 480),
        now: DateTime(2026, 10, 21));
    host.queue.add(const BackgroundJobRequest.check());
    await job().run();
    expect(sms.sentTo, hasLength(2));
    final s = (await schedules.forCampaign(id))!;
    expect(s.lastOutcome, ScheduleOutcome.started);
    final run = (await campaigns.get(s.lastRunCampaignId!))!;
    expect(run.status, CampaignStatus.completed);
    expect(host.results.single, startsWith('Reminder · Sun 25 Oct 2026, 08:00 finished'));
  });

  test('missed run (phone was off) is skipped with a notification, nothing sent', () async {
    final id = await campaign(1);
    await schedules.save(id, ScheduleSpec.weekly(weekdays: CampaignSchedule.bit(DateTime.sunday), minuteOfDay: 480),
        now: DateTime(2026, 10, 21));
    now = DateTime(2026, 10, 25, 11); // 3 hours late
    host.queue.add(const BackgroundJobRequest.check());
    await job().run();
    expect(sms.sentTo, isEmpty);
    expect(host.results.single, 'Reminder — Skipped: more than 2 hours late');
  });

  test('SMS permission missing: nothing sent, campaign stays ready, you are told why', () async {
    final id = await campaign(2);
    sms.caps = androidNoPermission;
    host.queue.add(BackgroundJobRequest.send(id));
    await job().run();
    expect(sms.sentTo, isEmpty);
    expect((await campaigns.get(id))!.status, CampaignStatus.ready);
    expect(host.results.single, 'Reminder was not sent — SMS permission is required to send through your SIM.');
  });

  test('a job queued while finishing is still processed', () async {
    final a = await campaign(1);
    final b = await composer.resend(a, ResendMode.sameRecipients, platform: 'android');
    host.queue.add(BackgroundJobRequest.send(a));
    host.lateJobs = [BackgroundJobRequest.send(b)];
    await job().run();
    expect(sms.sentTo, hasLength(2));
    expect(host.finishes, 2);
    expect((await campaigns.get(b))!.status, CampaignStatus.completed);
  });

  test('no callbacks: waits up to 2 minutes, then reports honestly and stops', () async {
    final id = await campaign(2);
    sms.callbacks = false;
    host.queue.add(BackgroundJobRequest.send(id));
    final start = now;
    await job().run();
    expect(now.difference(start), greaterThanOrEqualTo(deliveryWait));
    expect(host.results.single, 'Reminder finished — 2 sending');
    expect((await campaigns.get(id))!.status, CampaignStatus.running); // recovery marks these unknown later
  });

  test('pause requested from the app screen stops the background sender', () async {
    final id = await campaign(3);
    sms.callbacks = false;
    var sends = 0;
    final o = SendOrchestrator(sms: sms, attempts: AttemptRepository(db), campaigns: campaigns, sleep: (_) async {
      if (++sends == 1) await campaigns.requestPause(id); // user taps Pause after the first message
    });
    await o.runAndroid(id);
    expect(sms.sentTo, hasLength(1));
    expect((await campaigns.get(id))!.status, CampaignStatus.paused);
    expect((await campaigns.statusCounts(id))[RecipientStatus.pending], 2);
  });

  test('cancel from the app screen: remaining recipients are never sent', () async {
    final id = await campaign(3);
    var sends = 0;
    final o = SendOrchestrator(sms: sms, attempts: AttemptRepository(db), campaigns: campaigns, sleep: (_) async {
      if (++sends == 1) {
        await AttemptRepository(db).cancelPending(id);
        await campaigns.setStatus(id, CampaignStatus.cancelled);
      }
    });
    await o.runAndroid(id);
    expect(sms.sentTo, hasLength(1));
    expect((await campaigns.get(id))!.status, CampaignStatus.cancelled);
  });

  test('nextWake is the earliest enabled run', () async {
    final a = await campaign(1);
    final b = await composer.resend(a, ResendMode.sameRecipients, platform: 'android');
    expect(await schedules.nextWake(), isNull);
    await schedules.save(a, ScheduleSpec.weekly(weekdays: CampaignSchedule.bit(DateTime.friday), minuteOfDay: 1080), now: now);
    final sb = await schedules.save(b, ScheduleSpec.once(DateTime(2026, 10, 26, 9)), now: now);
    expect(await schedules.nextWake(), DateTime(2026, 10, 26, 9));
    await schedules.setEnabled(sb, false, now: now);
    expect(await schedules.nextWake(), DateTime(2026, 10, 30, 18));
  });
}
