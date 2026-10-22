import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late ContactRepository contacts;
  late GroupRepository groups;
  late CampaignRepository campaigns;
  late ScheduleRepository schedules;
  late CampaignComposer composer;
  late ScheduleRunner runner;
  late int groupId;

  final sunday8 = ScheduleSpec.weekly(weekdays: CampaignSchedule.bit(DateTime.sunday), minuteOfDay: 8 * 60);
  final wed = DateTime(2026, 10, 21, 12); // Wednesday
  final sunAt = DateTime(2026, 10, 25, 8);

  Future<int> person(String name, String phone, {ConsentStatus consent = ConsentStatus.unknown}) async {
    final id = await contacts.add(Contact(name: name, phoneRaw: phone, phoneNormalized: phone, consent: consent));
    await groups.addContacts(groupId, [id]);
    return id;
  }

  Future<int> campaign({String template = 'Hi {first_name}', Map<String, String> fallbacks = const {}}) async {
    final p = await composer.plan(template: template, groupIds: {groupId}, contactIds: {}, fallbacks: fallbacks);
    return composer.save(name: 'Sunday reminder', template: template, platform: 'android', plan: p,
        audience: CampaignAudience(groupIds: {groupId}), fallbacks: fallbacks);
  }

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    contacts = ContactRepository(db);
    groups = GroupRepository(db);
    campaigns = CampaignRepository(db);
    schedules = ScheduleRepository(db);
    composer = CampaignComposer(contacts: contacts, groups: groups, campaigns: campaigns);
    runner = ScheduleRunner(schedules: schedules, campaigns: campaigns, composer: composer);
    groupId = await groups.create('Church');
  });
  tearDown(() => db.close());

  group('saving a campaign', () {
    test('stores audience and fallbacks', () async {
      await person('Ada', '+2341');
      final id = await campaign(template: 'Hi {first_name}, see you at {place}', fallbacks: {'place': 'church'});
      expect((await campaigns.audience(id)).groupIds, {groupId});
      expect(await campaigns.fallbacks(id), {'place': 'church'});
    });
  });

  group('resend', () {
    test('same people: same messages, minus newly opted-out and suppressed; original untouched', () async {
      final ada = await person('Ada', '+2341');
      await person('Bola', '+2342');
      await person('Chidi', '+2343');
      final id = await campaign();
      await campaigns.setStatus(id, CampaignStatus.completed);
      await contacts.setConsent(ada, ConsentStatus.optedOut);
      await contacts.suppress('+2342');

      final again = await composer.resend(id, ResendMode.sameRecipients, platform: 'android');
      final c = (await campaigns.get(again))!;
      expect(c.status, CampaignStatus.ready);
      expect(c.sourceCampaignId, id);
      expect(c.name, 'Sunday reminder (again)');
      expect((await campaigns.recipients(again)).map((r) => r.renderedMessage), ['Hi Chidi']);
      expect((await campaigns.get(id))!.status, CampaignStatus.completed);
      expect(await campaigns.recipients(id), hasLength(3));
    });

    test('current audience includes people added since', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      await person('Bola', '+2342');
      final again = await composer.resend(id, ResendMode.currentAudience, platform: 'android');
      expect((await campaigns.recipients(again)).map((r) => r.name).toSet(), {'Ada', 'Bola'});
      expect((await campaigns.audience(again)).groupIds, {groupId});
    });

    test('refuses when nobody is left', () async {
      final ada = await person('Ada', '+2341');
      final id = await campaign();
      await contacts.setConsent(ada, ConsentStatus.optedOut);
      expect(() => composer.resend(id, ResendMode.sameRecipients, platform: 'android'),
          throwsA(isA<ResendRefusedException>()));
    });
  });

  group('ScheduleRunner', () {
    test('weekly: creates a run from current members and advances to next week', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      await person('Bola', '+2342'); // joined after the campaign was written
      await schedules.save(id, sunday8, now: wed);

      expect(await runner.runDue(DateTime(2026, 10, 25, 7, 59), platform: 'android', canAutoSend: true), isEmpty);
      final res = await runner.runDue(DateTime(2026, 10, 25, 8, 1), platform: 'android', canAutoSend: true);
      expect(res.single.outcome, ScheduleOutcome.started);
      final run = (await campaigns.get(res.single.campaignId!))!;
      expect(run.status, CampaignStatus.ready);
      expect(run.sourceCampaignId, id);
      expect(run.scheduleId, isNotNull);
      expect((await campaigns.recipients(run.id)).map((r) => r.name).toSet(), {'Ada', 'Bola'});

      final s = (await schedules.forCampaign(id))!;
      expect(s.nextRunAt, DateTime(2026, 11, 1, 8));
      expect(s.lastOutcome, ScheduleOutcome.started);
      expect(s.lastRunCampaignId, run.id);
      // Already handled: nothing more until next week.
      expect(await runner.runDue(DateTime(2026, 10, 25, 8, 30), platform: 'android', canAutoSend: true), isEmpty);
    });

    test('more than 2 hours late: skipped as missed, nothing created', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      await schedules.save(id, sunday8, now: wed);
      final before = (await campaigns.recent()).length;
      final res = await runner.runDue(DateTime(2026, 10, 25, 10, 1), platform: 'android', canAutoSend: true);
      expect(res.single.outcome, ScheduleOutcome.missed);
      expect((await campaigns.recent()).length, before);
      expect((await schedules.forCampaign(id))!.nextRunAt, DateTime(2026, 11, 1, 8));
    });

    test('waits while another campaign is sending (no overlap)', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      final other = await campaign();
      await campaigns.setStatus(other, CampaignStatus.running);
      await schedules.save(id, sunday8, now: wed);
      expect(await runner.runDue(sunAt, platform: 'android', canAutoSend: true), isEmpty);
      expect((await schedules.forCampaign(id))!.nextRunAt, sunAt); // still pending
      await campaigns.setStatus(other, CampaignStatus.completed);
      final res = await runner.runDue(sunAt.add(const Duration(minutes: 30)), platform: 'android', canAutoSend: true);
      expect(res.single.outcome, ScheduleOutcome.started);
    });

    test('device cannot send by itself: run prepared, needs attention', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      await schedules.save(id, sunday8, now: wed);
      final res = await runner.runDue(sunAt, platform: 'ios', canAutoSend: false);
      expect(res.single.outcome, ScheduleOutcome.needsAttention);
      expect((await campaigns.get(res.single.campaignId!))!.platform, 'ios');
    });

    test('missing values block the run; nobody eligible is recorded too', () async {
      await person('Ada', '+2341');
      final a = await campaign();
      // Edit the template so a variable has no value and no fallback.
      await campaigns.updateDraft(a, name: 'Sunday reminder', template: 'See you at {place}');
      await schedules.save(a, sunday8, now: wed);
      expect((await runner.runDue(sunAt, platform: 'android', canAutoSend: true)).single.outcome, ScheduleOutcome.blocked);

      final b = await campaign(template: 'Hello');
      await groups.removeContact(groupId, (await contacts.search()).single.id!); // group is now empty
      await schedules.save(b, sunday8, now: DateTime(2026, 10, 28));
      final res = await runner.runDue(DateTime(2026, 11, 1, 8), platform: 'android', canAutoSend: true);
      expect(res.map((r) => r.outcome), contains(ScheduleOutcome.noRecipients));
    });

    test('once: sends the campaign itself when ready, then switches off', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      await schedules.save(id, ScheduleSpec.once(DateTime(2026, 10, 22, 9)), now: wed);
      final res = await runner.runDue(DateTime(2026, 10, 22, 9), platform: 'android', canAutoSend: true);
      expect(res.single.campaignId, id);
      expect(res.single.outcome, ScheduleOutcome.started);
      final s = (await schedules.forCampaign(id))!;
      expect(s.enabled, false);
      expect(s.nextRunAt, isNull);
    });

    test('once: campaign no longer ready is not sent', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      await schedules.save(id, ScheduleSpec.once(DateTime(2026, 10, 22, 9)), now: wed);
      await campaigns.setStatus(id, CampaignStatus.completed);
      final res = await runner.runDue(DateTime(2026, 10, 22, 9), platform: 'android', canAutoSend: true);
      expect(res.single.outcome, ScheduleOutcome.notReady);
      expect(res.single.campaignId, isNull);
    });

    test('pause skips occurrences; resume picks the next one from now', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      final sid = await schedules.save(id, sunday8, now: wed);
      await schedules.setEnabled(sid, false, now: wed);
      expect(await runner.runDue(sunAt, platform: 'android', canAutoSend: true), isEmpty);
      await schedules.setEnabled(sid, true, now: DateTime(2026, 10, 25, 9));
      expect((await schedules.forCampaign(id))!.nextRunAt, DateTime(2026, 11, 1, 8));
    });

    test('deleting the campaign removes its schedule; runs keep their history', () async {
      await person('Ada', '+2341');
      final id = await campaign();
      await schedules.save(id, sunday8, now: wed);
      final run = (await runner.runDue(sunAt, platform: 'android', canAutoSend: true)).single.campaignId!;
      await campaigns.delete(id);
      expect(await schedules.list(), isEmpty);
      final kept = (await campaigns.get(run))!;
      expect(kept.sourceCampaignId, isNull);
      expect(await campaigns.recipients(run), hasLength(1));
    });
  });
}
