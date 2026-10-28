import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/core/phone_numbers/phone_normalizer.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/importers/contact_import_planner.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/birthday_settings.dart';
import 'package:sim_bulk_sms/domain/models/channels.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/pro.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/birthdays.dart';
import 'package:sim_bulk_sms/features/birthdays/birthday_runner.dart';
import 'package:sim_bulk_sms/platform/reminders/schedule_reminders.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('reading birthdays', () {
    test('common formats, day first by default', () {
      expect(parseBirthday('1990-05-17'), '1990-05-17');
      expect(parseBirthday('1990-05-17 00:00:00'), '1990-05-17');
      expect(parseBirthday('17/05/1990'), '1990-05-17');
      expect(parseBirthday('17-05-1990'), '1990-05-17');
      expect(parseBirthday('7.5.1990'), '1990-05-07');
      expect(parseBirthday('17/05'), '--05-17');
      expect(parseBirthday('17 May 1990'), '1990-05-17');
      expect(parseBirthday('17th May'), '--05-17');
      expect(parseBirthday('17-May-90'), '1990-05-17');
      expect(parseBirthday('May 17, 1990'), '1990-05-17');
      expect(parseBirthday('Sept 3'), '--09-03');
      expect(parseBirthday('--12-25'), '--12-25');
    });

    test('US month-first numbers; impossible dates and junk are rejected', () {
      expect(parseBirthday('05/17/1990', monthFirst: true), '1990-05-17');
      expect(parseBirthday('05/17/1990'), isNull); // month 17
      expect(parseBirthday('31/04/1990'), isNull);
      expect(parseBirthday('29/02/2023'), isNull);
      expect(parseBirthday('29/02/2024'), '2024-02-29');
      expect(parseBirthday('29/02'), '--02-29');
      expect(parseBirthday('soon'), isNull);
      expect(parseBirthday(''), isNull);
    });

    test('whose birthday is it: 29 February counts on the 28th in other years', () {
      expect(isBirthdayOn('1990-05-17', DateTime(2026, 5, 17)), true);
      expect(isBirthdayOn('--05-17', DateTime(2026, 5, 18)), false);
      expect(isBirthdayOn('2000-02-29', DateTime(2027, 2, 28)), true);
      expect(isBirthdayOn('2000-02-29', DateTime(2028, 2, 28)), false);
      expect(isBirthdayOn('2000-02-29', DateTime(2028, 2, 29)), true);
      expect(nextBirthday('--01-02', DateTime(2026, 12, 30)), DateTime(2027, 1, 2));
      expect(ageOn('1990-05-17', DateTime(2026, 5, 17)), 36);
      expect(ageOn('--05-17', DateTime(2026, 5, 17)), isNull);
    });
  });

  group('CSV import', () {
    final ng = PhoneNormalizer('NG');

    test('a row with only a valid email becomes an email-only contact; birthdays are read', () {
      final table = [
        ['Name', 'Phone', 'Email', 'Date of birth'],
        ['Ada', '08031234567', 'ada@example.com', '17/05/1990'],
        ['Bola', '', 'bola@example.com', '3 Sept'],
        ['Chidi', 'not a number', 'chidi@example.com', 'soon'],
        ['Dayo', '', 'dayo(at)example', ''],
        ['Bola again', '', 'BOLA@example.com', ''],
        ['Eze', '', 'eze@old.com', ''],
      ];
      final m = ColumnMapping.suggest(table.first)!;
      expect(m.birthday, 3);
      final plan = planImport(table: table, mapping: m, normalizer: ng, existingNormalized: {},
          existingEmails: {'eze@old.com'});
      expect(plan.valid, 3);
      expect(plan.emailOnlyCount, 2); // Bola, Chidi (invalid number but valid email)
      expect(plan.importable.map((r) => r.birthday), ['1990-05-17', '--09-03', null]);
      expect(plan.birthdaysUnreadable, 1); // "soon"
      expect(plan.invalidPhones, 1); // Dayo: neither
      expect(plan.repeatedInFile, 1); // Bola again
      expect(plan.existing.single.name, 'Eze');
    });

    test('a file with only an email column can be imported', () {
      final table = [['Name', 'Email'], ['Ada', 'ada@example.com']];
      final m = ColumnMapping.suggest(table.first)!;
      expect((m.phone, m.email), (null, 1));
      expect(planImport(table: table, mapping: m, normalizer: ng, existingNormalized: {}).emailOnlyCount, 1);
      final guessed = ColumnMapping.guess([['Ada', 'ada@example.com', '1990-05-17']], hasHeader: false, normalizer: ng)!;
      expect((guessed.email, guessed.birthday, guessed.name), (1, 2, 0));
    });

    test('email-only rows and birthdays are saved; existing emails join the group', () async {
      sqfliteFfiInit();
      final db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      addTearDown(db.close);
      final repo = ContactRepository(db);
      final eze = await repo.add(const Contact(name: 'Eze', phoneRaw: '', email: 'Eze@Old.com'));
      final table = [['Name', 'Phone', 'Email', 'Birthday'], ['Bola', '', 'bola@example.com', '3 Sept'],
          ['Eze', '', 'eze@old.com', '']];
      final plan = planImport(table: table, mapping: ColumnMapping.suggest(table.first)!, normalizer: ng,
          existingNormalized: await repo.existingNormalized(), existingEmails: await repo.existingEmails());
      final res = await repo.commitImportToGroup(plan, newGroupName: 'Choir');
      expect((res.added, res.inGroup), (1, 2));
      final bola = (await repo.search('Bola')).single;
      expect((bola.phoneNormalized, bola.phoneRaw, bola.birthday), (null, '', '--09-03'));
      expect(await GroupRepository(db).groupNamesOf(eze), ['Choir']);
    });
  });

  group('birthday wishes', () {
    late Database db;
    late SettingsRepository settings;
    late ContactRepository contacts;
    late CampaignRepository campaigns;
    late BirthdayRunner runner;
    final day = DateTime(2026, 5, 17, 9); // after 08:00

    setUp(() async {
      sqfliteFfiInit();
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      settings = SettingsRepository(db);
      contacts = ContactRepository(db);
      campaigns = CampaignRepository(db);
      runner = BirthdayRunner(db: db, settings: settings, contacts: contacts, groups: GroupRepository(db),
          campaigns: campaigns);
      await contacts.add(const Contact(name: 'Ada Okafor', phoneRaw: '0803', phoneNormalized: '+2348031234567',
          birthday: '1990-05-17'));
      await contacts.add(const Contact(name: 'Bola', phoneRaw: '', email: 'bola@example.com', birthday: '--05-17'));
      await contacts.add(const Contact(name: 'Chidi', phoneRaw: '0805', phoneNormalized: '+2348051234567',
          birthday: '--05-18'));
      await contacts.add(const Contact(name: 'Out', phoneRaw: '0806', phoneNormalized: '+2348061234567',
          birthday: '--05-17', consent: ConsentStatus.optedOut));
      await settings.saveBirthdays(const BirthdaySettings(enabled: true, channel: SendChannel.smsElseEmail));
      await settings.savePro(ProStatus(active: true, verifiedAt: DateTime.now()));
    });
    tearDown(() => db.close());

    test('Pro only, and not before the chosen time', () async {
      await settings.savePro(const ProStatus());
      expect((await runner.runDue(day, platform: 'android')).outcome, BirthdayOutcome.needsPro);
      expect(await runner.nextRunAt(day), isNull);
      await settings.savePro(ProStatus(active: true, verifiedAt: DateTime.now()));
      expect((await runner.runDue(DateTime(2026, 5, 17, 7, 59), platform: 'android')).outcome, BirthdayOutcome.notDue);
      expect(await runner.nextRunAt(DateTime(2026, 5, 17, 7)), DateTime(2026, 5, 17, 8));
    });

    test("today's birthdays get one campaign (texts and emails), opted-out people left out", () async {
      final r = await runner.runDue(day, platform: 'android');
      expect((r.outcome, r.people, r.texts), (BirthdayOutcome.created, 2, 1));
      final c = (await campaigns.get(r.campaignId!))!;
      expect(c.name, 'Birthday wishes · 17 May');
      final rows = await campaigns.recipients(c.id);
      expect(rows.map((x) => '${x.name}:${x.channel.name}'), ['Ada Okafor:sms', 'Bola:email']);
      expect(rows.first.renderedMessage, startsWith('Happy birthday Ada!'));
      expect(await runner.nextRunAt(day), DateTime(2026, 5, 18, 8)); // done for today
    });

    test('never twice: not again the same day, nor the same year', () async {
      await runner.runDue(day, platform: 'android');
      expect((await runner.runDue(day.add(const Duration(hours: 1)), platform: 'android')).outcome, BirthdayOutcome.notDue);
      // Even if the day's run were lost, people already wished this year are skipped.
      await settings.saveBirthdays((await settings.loadBirthdays()).copyWith(lastRunDate: '2000-01-01'));
      expect((await runner.runDue(day, platform: 'android')).outcome, BirthdayOutcome.none);
    });

    test('only the chosen groups; upcoming list and reminders', () async {
      final groups = GroupRepository(db);
      final g = await groups.create('Choir');
      final chidi = (await contacts.search('Chidi')).single;
      await groups.addContacts(g, [chidi.id!]);
      await settings.saveBirthdays((await settings.loadBirthdays()).copyWith(groupIds: {g}));
      expect((await runner.runDue(day, platform: 'android')).outcome, BirthdayOutcome.none); // Ada isn't in the choir
      final up = await runner.upcoming(day);
      expect(up.map((u) => (u.contact.name, u.on)), [('Chidi', DateTime(2026, 5, 18))]);
      final rem = birthdayReminders(up, await settings.loadBirthdays(), day);
      expect((rem.single.title, rem.single.at), ("Chidi's birthday is today", DateTime(2026, 5, 18, 8)));
    });
  });
}
