import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/schedule_repository.dart';
import 'package:sim_bulk_sms/domain/models/schedule.dart';
import 'package:sim_bulk_sms/features/backup/backup_sync.dart';
import 'package:sim_bulk_sms/features/backup/campaign_plans.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_composer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A tiny in-memory Contacts++ sync server.
class _Server implements SyncTransport {
  final records = <String, SyncRecord>{};
  var seq = 0;
  final pushes = <List<SyncRecord>>[];

  @override
  Future<int> push(List<SyncRecord> batch) async {
    pushes.add(batch);
    for (final r in batch) {
      records['${r.kind}/${r.key}'] = SyncRecord(kind: r.kind, key: r.key, data: r.data, deleted: r.deleted, seq: ++seq);
    }
    return seq;
  }

  @override
  Future<({List<SyncRecord> records, int cursor, bool hasMore})> pull(int since, {int limit = 500}) async {
    final changed = records.values.where((r) => r.seq > since).toList()..sort((a, b) => a.seq.compareTo(b.seq));
    final page = changed.take(limit).toList();
    return (records: page, cursor: page.isEmpty ? since : page.last.seq, hasMore: changed.length > limit);
  }

  void web(String kind, String key, Map<String, dynamic>? data) =>
      records['$kind/$key'] = SyncRecord(kind: kind, key: key, data: data, deleted: data == null, seq: ++seq);

  List<SyncRecord> pushedOf(String kind) => [for (final b in pushes) ...b.where((r) => r.kind == kind)];
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late _Server server;
  late BackupSync sync;
  late CampaignRepository campaigns;
  late ScheduleRepository schedules;
  var clock = DateTime(2026, 11, 12, 10, 0, 30);

  Map<String, dynamic> plan({Object? schedule, String name = 'Choir practice', String updatedAt = '2026-11-12T09:00:00.000Z'}) => {
        'name': name,
        'template': 'Hi {first_name}, practice at 6',
        'channel': 'sms',
        'audience': {'groups': ['g-1'], 'contacts': <String>[]},
        'fallbacks': <String, String>{},
        'schedule': schedule,
        'enabled': true,
        'updated_at': updatedAt,
      };

  Future<int> onlyCampaign() async => (await db.query('campaigns')).single['id'] as int;

  setUp(() async {
    clock = DateTime(2026, 11, 12, 10, 0, 30);
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    server = _Server();
    campaigns = CampaignRepository(db);
    schedules = ScheduleRepository(db);
    sync = BackupSync(
      db: db,
      transport: server,
      clock: () => clock,
      plans: CampaignPlans(
        db: db,
        campaigns: campaigns,
        schedules: schedules,
        composer: CampaignComposer(contacts: ContactRepository(db), groups: GroupRepository(db), campaigns: campaigns),
        platform: 'android',
        clock: () => clock,
      ),
    );
    // People and a group made on the web.
    server.web('contact', 'c-1', {'name': 'Bola Ade', 'phone': '+2348031111111'});
    server.web('contact', 'c-2', {'name': 'Chika', 'phone': '+2348032222222'});
    server.web('group', 'g-1', {'name': 'Choir', 'members': ['c-1', 'c-2']});
  });
  tearDown(() => db.close());

  test('a campaign set up on the web is saved, scheduled and reported back', () async {
    server.web('campaign_plan', 'p-1', plan(schedule: {'kind': 'once', 'at': DateTime(2026, 11, 20, 18).toUtc().toIso8601String()}));
    final report = await sync.run(full: false);
    expect(report.downloaded, 4);

    final id = await onlyCampaign();
    final c = (await campaigns.get(id))!;
    expect(c.name, 'Choir practice');
    expect(c.status.name, 'ready');
    expect(c.recipientCount, 2);
    final s = (await schedules.forCampaign(id))!;
    expect(s.kind, ScheduleKind.once);
    expect(s.nextRunAt, DateTime(2026, 11, 20, 18));

    // Not echoed back; its status is.
    expect(server.pushedOf(CampaignPlans.planKind), isEmpty);
    final status = server.records['campaign_status/p-1']!.data!;
    expect(status['state'], 'scheduled');
    expect(status['applied_updated_at'], '2026-11-12T09:00:00.000Z');
    expect(status['recipients'], 2);

    expect((await sync.run(full: false)).uploaded, 0, reason: 'nothing changed');
  });

  test('"Send now" from the web runs at the next minute', () async {
    server.web('campaign_plan', 'p-1', plan());
    await sync.run(full: false);
    final s = (await schedules.forCampaign(await onlyCampaign()))!;
    expect(s.nextRunAt, DateTime(2026, 11, 12, 10, 1));
  });

  test('a one-time send that came due while the phone was offline still goes, within a day', () async {
    server.web('campaign_plan', 'late', plan(schedule: {'kind': 'once', 'at': DateTime(2026, 11, 12, 8).toUtc().toIso8601String()}));
    await sync.run(full: false);
    expect((await schedules.forCampaign(await onlyCampaign()))!.nextRunAt, DateTime(2026, 11, 12, 10, 1));
  });

  test('weekly plans keep their days and time', () async {
    server.web('campaign_plan', 'p-1', plan(schedule: {'kind': 'weekly', 'weekdays': 1 | 4, 'minute_of_day': 18 * 60, 'ends_on': null}));
    await sync.run(full: false);
    final s = (await schedules.forCampaign(await onlyCampaign()))!;
    expect(s.weekdays, 5);
    expect(s.minuteOfDay, 1080);
    // Thursday 12 Nov 2026, 10:00 → next Monday or Wednesday at 18:00.
    expect(s.nextRunAt, DateTime(2026, 11, 16, 18));
  });

  test('a web edit updates the phone; a newer phone edit wins over an older web edit', () async {
    server.web('campaign_plan', 'p-1', plan(schedule: {'kind': 'once', 'at': DateTime(2026, 11, 20, 18).toUtc().toIso8601String()}));
    await sync.run(full: false);
    final id = await onlyCampaign();

    server.web('campaign_plan', 'p-1', plan(name: 'Choir practice (moved)', updatedAt: '2026-11-12T09:30:00.000Z',
        schedule: {'kind': 'once', 'at': DateTime(2026, 11, 21, 18).toUtc().toIso8601String()}));
    await sync.run(full: false);
    expect((await campaigns.get(id))!.name, 'Choir practice (moved)');
    expect((await schedules.forCampaign(id))!.nextRunAt, DateTime(2026, 11, 21, 18));
    expect(server.records['campaign_status/p-1']!.data!['applied_updated_at'], '2026-11-12T09:30:00.000Z');

    // Edited on the phone after that (now), and an older web edit arrives.
    await campaigns.updateDraft(id, name: 'Renamed on the phone', template: 'Hi {first_name}, practice at 6');
    server.web('campaign_plan', 'p-1', plan(name: 'Old web edit', updatedAt: '2026-11-12T09:45:00.000Z'));
    await sync.run(full: false);
    expect((await campaigns.get(id))!.name, 'Renamed on the phone');
    expect(server.records['campaign_plan/p-1']!.data!['name'], 'Renamed on the phone', reason: 'the phone’s newer edit is uploaded');
  });

  test('once sending has started, web edits are refused and the web is told', () async {
    server.web('campaign_plan', 'p-1', plan(schedule: {'kind': 'once', 'at': DateTime(2026, 11, 20, 18).toUtc().toIso8601String()}));
    await sync.run(full: false);
    final id = await onlyCampaign();
    await db.update('campaigns', {'status': 'running'}, where: 'id = ?', whereArgs: [id]);

    server.web('campaign_plan', 'p-1', plan(name: 'Too late', updatedAt: '2026-11-12T11:00:00.000Z'));
    await sync.run(full: false);
    expect((await campaigns.get(id))!.name, 'Choir practice');
    final status = server.records['campaign_status/p-1']!.data!;
    expect(status['state'], 'sending');
    expect(status['message'], contains('wasn’t applied'));
  });

  test('a plan nobody can receive is kept as a draft and explained', () async {
    server.web('campaign_plan', 'p-1', {...plan(), 'audience': {'groups': <String>[], 'contacts': <String>[]}});
    await sync.run(full: false);
    final id = await onlyCampaign();
    expect((await campaigns.get(id))!.status.name, 'draft');
    final status = server.records['campaign_status/p-1']!.data!;
    expect(status['state'], 'needs_attention');
    expect(status['message'], contains('No one'));
  });

  test('deleting on the web removes a campaign that hasn’t sent', () async {
    server.web('campaign_plan', 'p-1', plan(schedule: {'kind': 'once', 'at': DateTime(2026, 11, 20, 18).toUtc().toIso8601String()}));
    await sync.run(full: false);
    server.web('campaign_plan', 'p-1', null);
    await sync.run(full: false);
    expect(await db.query('campaigns'), isEmpty);
    expect(await db.query('campaign_schedules'), isEmpty);
  });

  test('without backup, this phone’s own campaigns stay on the phone', () async {
    await campaigns.createDraft(name: 'Phone only', template: 'Hi', platform: 'android');
    await sync.run(full: false);
    expect(server.pushedOf(CampaignPlans.planKind), isEmpty);
    await sync.run(full: true);
    expect(server.pushedOf(CampaignPlans.planKind).single.data!['name'], 'Phone only');
  });
}
