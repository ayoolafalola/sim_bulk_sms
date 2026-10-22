import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/database/schema_v1.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/domain/models/campaign.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('a v1 database upgrades to v2 and keeps its data', () async {
    final dir = Directory.systemTemp.createTempSync('sim_bulk_sms_migration');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'app.db');

    final v1 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
          for (final s in schemaV1) { await db.execute(s); }
        }));
    final now = DateTime.now().toUtc().toIso8601String();
    await v1.insert('campaigns', {'name': 'Old', 'message_template': 'Hi', 'status': 'completed',
      'platform': 'android', 'recipient_count': 0, 'created_at': now, 'updated_at': now});
    await v1.close();

    final db = await openAppDatabase(databaseFactoryFfi, path);
    addTearDown(db.close);
    expect(await db.getVersion(), 2);
    final repo = CampaignRepository(db);
    final old = (await repo.recent()).single;
    expect(old.name, 'Old');
    expect(old.sourceCampaignId, isNull);
    // New tables and columns work.
    await repo.saveAudience(old.id, const CampaignAudience(groupIds: {}, contactIds: {}));
    await repo.saveFallbacks(old.id, {'event': 'the fair'});
    expect(await repo.fallbacks(old.id), {'event': 'the fair'});
    expect(await db.query('campaign_schedules'), isEmpty);
  });
}
