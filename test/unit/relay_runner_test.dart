import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/features/relay/relay_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Transport implements RelayTransport {
  List<RelayBatch> waiting = [];
  final reports = <Map<String, dynamic>>[];
  @override
  Future<List<RelayBatch>> claim() async {
    final out = waiting;
    waiting = [];
    return out;
  }

  @override
  Future<void> report(List<Map<String, dynamic>> results) async => reports.addAll(results);
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late _Transport transport;
  late RelayRunner runner;
  late CampaignRepository campaigns;

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    transport = _Transport();
    campaigns = CampaignRepository(db);
    runner = RelayRunner(db: db, transport: transport, campaigns: campaigns);
  });
  tearDown(() => db.close());

  test('texts from the web become a ready campaign; opted-out numbers are never texted', () async {
    await db.insert('suppression_list', {'phone_number_normalized': '+2348039999999', 'created_at': '2026-11-11'});
    transport.waiting = [
      const RelayBatch(id: 'b1', name: 'Choir', jobs: [
        RelayJob(id: 'j1', to: '+2348031111111', body: 'Practice at 6', name: 'Bola'),
        RelayJob(id: 'j2', to: '+2348039999999', body: 'Practice at 6'),
      ]),
    ];

    final ids = await runner.claim();

    final campaign = (await campaigns.get(ids.single))!;
    expect(campaign.name, 'From the web · Choir');
    final recipients = await campaigns.recipients(ids.single);
    expect(recipients.map((r) => r.phone), ['+2348031111111']);
    expect(transport.reports, [
      {'id': 'j2', 'status': 'opted_out', 'error_code': 'opted_out'},
    ]);
  });

  test('a text handed out again is not made into a second campaign', () async {
    const batch = RelayBatch(id: 'b1', jobs: [RelayJob(id: 'j1', to: '+2348031111111', body: 'Hi')]);
    transport.waiting = [batch];
    final first = await runner.claim();
    transport.waiting = [batch];

    expect(await runner.claim(), isEmpty);
    expect(await runner.unstarted(), first, reason: 'the held one is still sent from here');
    expect(transport.reports, isEmpty);
  });

  test('results go back once per change, with "sent" before "delivered"', () async {
    transport.waiting = [
      const RelayBatch(id: 'b1', jobs: [RelayJob(id: 'j1', to: '+2348031111111', body: 'Hi')]),
    ];
    final id = (await runner.claim()).single;
    final row = (await campaigns.recipients(id)).single;

    expect(await runner.reportResults(), 0, reason: 'still pending');
    await db.update('campaign_recipients', {'status': 'delivered'}, where: 'id = ?', whereArgs: [row.id]);
    await runner.reportResults();
    expect(transport.reports.map((r) => r['status']), ['sent', 'delivered']);
    expect(await runner.reportResults(), 0);
  });

  test('claimed texts that never started sending are picked up again', () async {
    transport.waiting = [
      const RelayBatch(id: 'b1', jobs: [RelayJob(id: 'j1', to: '+2348031111111', body: 'Hi')]),
      const RelayBatch(id: 'b2', jobs: [RelayJob(id: 'j2', to: '+2348032222222', body: 'Hello')]),
    ];
    final ids = await runner.claim();
    expect(await runner.unstarted(), ids, reason: 'both still ready, never started');

    await db.update('campaigns', {'status': 'running'}, where: 'id = ?', whereArgs: [ids.first]);
    expect(await runner.unstarted(), [ids.last]);

    await db.update('campaigns', {'status': 'running'}, where: 'id = ?', whereArgs: [ids.last]);
    expect(await runner.unstarted(), isEmpty);
  });
}
