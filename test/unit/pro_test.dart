import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/attempt_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/schedule_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/channels.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/email_settings.dart';
import 'package:sim_bulk_sms/domain/models/pro.dart';
import 'package:sim_bulk_sms/domain/models/schedule.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/domain/services/email_body.dart';
import 'package:sim_bulk_sms/domain/services/send_limits.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_composer.dart';
import 'package:sim_bulk_sms/features/scheduling/schedule_runner.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/email/email_sender.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

class FakeSms implements SmsCapabilityService {
  final bodies = <String>[];
  final controller = StreamController<SmsEvent>.broadcast();
  @override Future<SmsCapabilities> getCapabilities() async => androidOk;
  @override Future<bool> requestRequiredPermissions() async => true;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => controller.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async {
    bodies.add(r.body);
    return const SmsOperationResult(RecipientStatus.submitted);
  }
}

class FakeMailer implements EmailSender {
  final sent = <OutgoingEmail>[];
  @override Future<void> prepare() async {}
  @override
  Future<EmailResult> send(OutgoingEmail e) async {
    sent.add(e);
    return const EmailResult(EmailOutcome.sent);
  }
}

void main() {
  final now = DateTime(2026, 10, 22, 12);
  final pro = ProStatus(active: true, verifiedAt: now.subtract(const Duration(days: 1)));

  group('Pro status', () {
    test('free, active, stale, expired and debug', () {
      expect(const ProStatus().isPro(now: now), false);
      expect(pro.isPro(now: now), true);
      expect(pro.isPro(now: now.add(const Duration(days: 7))), false); // not re-checked for a week
      final apple = ProStatus(active: true, verifiedAt: now, expiresAt: now.subtract(const Duration(days: 4)));
      expect(apple.isPro(now: now), false); // ended more than 3 days ago
      expect(const ProStatus(debugOverride: true).isPro(now: now), true);
      expect(ProStatus.fromJson(pro.toJson()).isPro(now: now), true);
    });

    test('signature: fixed on free; yours or none on Pro', () {
      expect(campaignSignature(const ProStatus(), custom: 'Mine', now: now), freeSignature);
      expect(campaignSignature(pro, custom: ' Grace Church ', now: now), 'Grace Church');
      expect(campaignSignature(pro, custom: '', now: now), isNull);
      expect(withSignature('Hi', freeSignature), 'Hi\nSent via messages.comeriver.com');
      expect(withSignature('Hi', null), 'Hi');
    });

    test('emails end with the signature (linked) before the unsubscribe line', () {
      final b = emailBodies('Hello', const EmailSettings(unsubscribeText: 'Reply STOP'), signature: freeSignature);
      expect(b.text, 'Hello\n\n--\nSent via messages.comeriver.com\nReply STOP');
      expect(b.html, contains('<a href="https://messages.comeriver.com"'));
    });

    test('the signature is counted in the SMS estimate', () {
      final p = buildSnapshotPlan(template: 'x' * 140, smsSignature: freeSignature, suppressedE164: const {},
          contacts: const [Contact(id: 1, name: 'A', phoneRaw: '1', phoneNormalized: '+2348031234567')]);
      expect(p.estimate.totalSegments, 2); // 140 + newline + 31 > 160
      expect(p.recipients.single.renderedMessage, 'x' * 140); // the snapshot keeps the bare message
    });
  });

  group('free limits', () {
    sqfliteFfiInit();
    late Database db;
    late CampaignRepository campaigns;
    late SettingsRepository settings;
    late CampaignComposer composer;
    late int groupId;

    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      campaigns = CampaignRepository(db);
      settings = SettingsRepository(db);
      final contacts = ContactRepository(db);
      final groups = GroupRepository(db);
      final id = await contacts.add(const Contact(name: 'Ada', phoneRaw: '0803', phoneNormalized: '+2348031234567'));
      groupId = await groups.create('Choir');
      await groups.addContacts(groupId, [id]);
      composer = CampaignComposer(contacts: contacts, groups: groups, campaigns: campaigns, proStatus: settings.loadPro);
    });
    tearDown(() => db.close());

    Future<int> save(String name) async => composer.save(
        name: name, template: 'Hi', platform: 'android',
        plan: await composer.plan(template: 'Hi', groupIds: {groupId}, contactIds: const {}));

    test('5 saved campaigns on the free app; drafts and re-saves don\'t count; Pro has no limit', () async {
      final ids = [for (var i = 1; i <= 5; i++) await save('C$i')];
      await campaigns.createDraft(name: 'Draft', template: 'x', platform: 'android');
      await composer.save(
          campaignId: ids.first, name: 'C1 edited', template: 'Hi', platform: 'android',
          plan: await composer.plan(template: 'Hi', groupIds: {groupId}, contactIds: const {}));
      await expectLater(save('C6'), throwsA(isA<ProRequiredException>()));
      await expectLater(composer.resend(ids.first, ResendMode.sameRecipients, platform: 'android'),
          throwsA(isA<ProRequiredException>()));
      await campaigns.delete(ids.last);
      await save('C6'); // a slot is free again
      await settings.savePro(ProStatus(active: true, verifiedAt: DateTime.now()));
      await save('C7');
      expect(await campaigns.countSavedCampaigns(), 6); // 5 - 1 deleted + C6 + C7 (the draft never counts)
    });

    test('1 schedule on the free app; only the first one runs after Pro ends', () async {
      final schedules = ScheduleRepository(db);
      final a = await save('A'), b = await save('B');
      final at = DateTime.now().add(const Duration(hours: 1));
      await schedules.save(a, ScheduleSpec.once(at), now: DateTime.now(), maxSchedules: FreeLimits.schedules);
      await expectLater(
          schedules.save(b, ScheduleSpec.once(at), now: DateTime.now(), maxSchedules: FreeLimits.schedules),
          throwsA(isA<ProRequiredException>()));
      await schedules.save(a, ScheduleSpec.once(at.add(const Duration(minutes: 5))),
          now: DateTime.now(), maxSchedules: FreeLimits.schedules); // editing its own schedule is fine
      await schedules.save(b, ScheduleSpec.once(at), now: DateTime.now()); // made while Pro

      final runner = ScheduleRunner(schedules: schedules, campaigns: campaigns, composer: composer,
          proStatus: settings.loadPro);
      final results = await runner.runDue(at.add(const Duration(minutes: 10)), platform: 'android', canAutoSend: true);
      expect(results.map((r) => r.outcome), containsAll([ScheduleOutcome.started, ScheduleOutcome.needsPro]));
      expect(results.firstWhere((r) => r.outcome == ScheduleOutcome.started).campaignId, a);
    });
  });

  group('sending', () {
    late Database db;
    late CampaignRepository campaigns;
    late AttemptRepository attempts;
    late SettingsRepository settings;
    late FakeSms sms;
    late FakeMailer mailer;

    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      campaigns = CampaignRepository(db);
      attempts = AttemptRepository(db);
      settings = SettingsRepository(db);
      sms = FakeSms();
      mailer = FakeMailer();
      await settings.saveEmail(const EmailSettings(
          provider: EmailProvider.mailgun, domain: 'd', apiKey: 'k', fromAddress: 'a@d.com', dailyLimit: 400,
          hourlyLimit: 0, unsubscribeOn: false));
    });
    tearDown(() => db.close());

    SendOrchestrator orch() => SendOrchestrator(sms: sms, attempts: attempts, campaigns: campaigns, settings: settings,
        emailSender: () async => mailer, sleep: (_) async {});

    Future<int> campaign({int texts = 1, int emails = 1}) async {
      final id = await campaigns.createDraft(name: 'C', template: 'Hi', platform: 'android', channel: SendChannel.both);
      await campaigns.saveSnapshot(id, [
        for (var i = 0; i < texts; i++) SnapshotRecipient(name: 'T$i', phoneE164: '+100$i', renderedMessage: 'Hi'),
        for (var i = 0; i < emails; i++)
          SnapshotRecipient(name: 'E$i', phoneE164: '', renderedMessage: 'Hi', channel: MessageChannel.email,
              email: 'e$i@x.com', subject: 'S'),
      ]);
      return id;
    }

    test('free: texts and emails carry the signature, and the sent text is recorded', () async {
      await orch().runAndroid(await campaign());
      expect(sms.bodies, ['Hi\nSent via messages.comeriver.com']);
      expect(mailer.sent.single.text, contains(freeSignature));
      final rows = await db.query('send_attempts', columns: ['sent_body'], where: "platform = 'android'");
      expect(rows.single['sent_body'], 'Hi\nSent via messages.comeriver.com');
    });

    test('Pro: your signature, or none', () async {
      await settings.savePro(ProStatus(active: true, verifiedAt: DateTime.now()));
      await settings.setCustomSignature('Grace Church');
      await orch().runAndroid(await campaign(emails: 0));
      await settings.setCustomSignature('');
      await orch().runAndroid(await campaign(emails: 0));
      expect(sms.bodies, ['Hi\nGrace Church', 'Hi']);
    });

    test('free: 50 emails a day, whatever the email settings say', () async {
      final id = await campaign(texts: 0, emails: 1);
      final rid = (await campaigns.recipients(id)).single.id;
      final t = DateTime.now().subtract(const Duration(hours: 2)).toUtc().toIso8601String();
      for (var i = 0; i < FreeLimits.emailsPerDay; i++) {
        await db.insert('send_attempts', {'campaign_recipient_id': rid, 'attempt_number': 100 + i, 'platform': 'email',
            'status': 'sent', 'initiated_at': t});
      }
      final hit = await orch().runAndroid(id);
      expect((hit?.email, hit?.kind), (true, LimitKind.daily));
      expect(mailer.sent, isEmpty);
      await settings.savePro(ProStatus(active: true, verifiedAt: DateTime.now()));
      await campaigns.setStatus(id, CampaignStatus.paused);
      await orch().runAndroid(id);
      expect(mailer.sent, hasLength(1)); // Pro: the email settings' 400 a day applies
    });
  });
}
