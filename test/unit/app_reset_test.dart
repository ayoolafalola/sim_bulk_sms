import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/app_info.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/email_settings.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/features/settings/app_reset.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('reset empties every table, keeps the schema, and ids start again', () async {
    final db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    addTearDown(db.close);
    final contacts = ContactRepository(db), groups = GroupRepository(db), campaigns = CampaignRepository(db);
    final settings = SettingsRepository(db);
    final c = await contacts.add(const Contact(name: 'Ada', phoneRaw: '0803', phoneNormalized: '+2348031234567'));
    final g = await groups.create('Choir');
    await groups.addContacts(g, [c]);
    final id = await campaigns.createDraft(name: 'C', template: 'Hi', platform: 'android');
    await campaigns.saveSnapshot(id, const [SnapshotRecipient(name: 'Ada', phoneE164: '+2348031234567', renderedMessage: 'Hi')]);
    await settings.setFlag('onboarding_done', true);
    await settings.saveEmail(const EmailSettings(provider: EmailProvider.mailgun, apiKey: 'secret'));

    await resetAppData(db);

    for (final r in await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")) {
      final n = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM ${r['name']}'));
      expect(n, 0, reason: '${r['name']} still has rows');
    }
    expect(await settings.flag('onboarding_done'), false); // the welcome screen shows again
    expect((await settings.loadEmail()).apiKey, '');
    expect(await groups.create('New'), 1); // fresh ids, foreign keys back on
    expect(Sqflite.firstIntValue(await db.rawQuery('PRAGMA foreign_keys')), 1);
  });

  test('the version shown in the app matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':').last.trim().split('+').first, appVersion);
  });
}
