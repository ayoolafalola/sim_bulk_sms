import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/features/backup/backup_sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A tiny in-memory Contacts++ sync server.
class _Server implements SyncTransport {
  final records = <String, SyncRecord>{}; // "kind/key" → latest
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

  /// A change made on the web.
  void webEdit(String kind, String key, Map<String, dynamic>? data) =>
      records['$kind/$key'] = SyncRecord(kind: kind, key: key, data: data, deleted: data == null, seq: ++seq);
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late _Server server;
  late BackupSync sync;
  const now = '2026-11-11T10:00:00Z';

  Future<int> contact(String name, String phone) => db.insert('contacts', {
        'name': name, 'phone_raw': phone, 'phone_normalized': phone, 'created_at': now, 'updated_at': now,
      });

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    server = _Server();
    sync = BackupSync(db: db, transport: server, clock: () => DateTime.utc(2026, 11, 11, 12));
  });
  tearDown(() => db.close());

  test('backs up contacts, groups and campaigns, then sends only what changed', () async {
    final bola = await contact('Bola', '+2348031111111');
    final group = await db.insert('recipient_groups', {'name': 'Choir', 'created_at': now, 'updated_at': now});
    await db.insert('group_contacts', {'group_id': group, 'contact_id': bola});

    final first = await sync.run();
    expect(first.uploaded, 2);
    final groupRecord = server.records.values.firstWhere((r) => r.kind == 'group');
    final contactRecord = server.records.values.firstWhere((r) => r.kind == 'contact');
    expect(groupRecord.data!['members'], [contactRecord.key]);

    expect((await sync.run()).uploaded, 0, reason: 'nothing changed');

    await db.update('contacts', {'name': 'Bola A.'}, where: 'id = ?', whereArgs: [bola]);
    final third = await sync.run();
    expect(third.uploaded, 1);
    expect(server.records['contact/${contactRecord.key}']!.data!['name'], 'Bola A.');
  });

  test('changes made on the web arrive on the phone and are not uploaded back', () async {
    await contact('Bola', '+2348031111111');
    await sync.run();
    final key = server.records.values.single.key;
    final pushesBefore = server.pushes.length;

    server.webEdit('contact', key, {'name': 'Bola from the web', 'phone': '+2348031111111'});
    server.webEdit('contact', 'web-new', {'name': 'Chika', 'phone': '+2348032222222'});
    server.webEdit('group', 'web-group', {'name': 'Ushers', 'members': ['web-new']});
    final report = await sync.run();

    expect(report.downloaded, 3);
    expect((await db.query('contacts', orderBy: 'id')).map((r) => r['name']), ['Bola from the web', 'Chika']);
    final members = await db.rawQuery('SELECT c.name FROM group_contacts gc JOIN contacts c ON c.id = gc.contact_id');
    expect(members.single['name'], 'Chika');
    expect(server.pushes.length, pushesBefore, reason: 'web changes are not echoed back');
  });

  test('deleting here deletes everywhere; deleting on the web never removes phone-book contacts', () async {
    final a = await contact('Ada', '+2348030000001');
    await db.insert('contacts', {
      'name': 'From phone', 'phone_raw': '+2348030000002', 'phone_normalized': '+2348030000002',
      'source': 'phone', 'created_at': now, 'updated_at': now,
    });
    await sync.run();

    await db.delete('contacts', where: 'id = ?', whereArgs: [a]);
    final report = await sync.run();
    expect(report.removed, 1);
    expect(server.records.values.where((r) => r.deleted).length, 1);

    final phoneKey = server.records.values.firstWhere((r) => !r.deleted).key;
    server.webEdit('contact', phoneKey, null);
    await sync.run();
    expect((await db.query('contacts')).single['name'], 'From phone');
  });

  test('a web contact with a number already on the phone is linked, not duplicated', () async {
    await contact('Bola', '+2348031111111');
    server.webEdit('contact', 'web-1', {'name': 'Bola (web)', 'phone': '+2348031111111'});

    await sync.run();

    expect(await db.query('contacts'), hasLength(1));
  });
}
