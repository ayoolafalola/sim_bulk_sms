import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/core/phone_numbers/phone_normalizer.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/importers/contact_import_planner.dart';
import 'package:sim_bulk_sms/data/importers/csv_decode.dart';
import 'package:sim_bulk_sms/data/importers/csv_parser.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  final ng = PhoneNormalizer('NG');

  group('decodeCsvBytes', () {
    test('UTF-8 (with BOM handled by the parser)', () =>
        expect(parseCsv(decodeCsvBytes(Uint8List.fromList(utf8.encode('﻿name,phone\nAdé,0803'))))[1][0], 'Adé'));
    test('Windows/Excel encoding falls back correctly, including smart quotes', () {
      final bytes = Uint8List.fromList([...latin1.encode('Ad'), 0xE9, ...latin1.encode(' O'), 0x92, ...latin1.encode('Neil')]);
      expect(decodeCsvBytes(bytes), 'Adé O’Neil');
    });
    test('Excel workbook is refused with instructions', () => expect(
        () => decodeCsvBytes(Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0, 0])),
        throwsA(isA<CsvFormatException>().having((e) => e.message, 'message', contains('CSV UTF-8')))));
  });

  group('column detection', () {
    test('register-style headers: surname + other names + GSM', () {
      final m = ColumnMapping.suggest(['S/N', 'Surname', 'Other Names', 'GSM No.', 'E-mail'])!;
      expect((m.name, m.firstName, m.lastName, m.phone, m.email), (null, 2, 1, 3, 4));
    });
    test('header row vs data row', () {
      expect(ColumnMapping.looksLikeHeader(['Name', 'Phone'], ng), true);
      expect(ColumnMapping.looksLikeHeader(['Ada', '08031234567'], ng), false);
    });
    test('no headers: guessed from the contents', () {
      final t = [
        ['08031234567', 'Ada Lovelace', 'ada@example.com'],
        ['0805 999 0000', 'Charles Babbage', ''],
        ['+2347012223333', 'Grace', 'g@example.com'],
      ];
      final m = ColumnMapping.guess(t, hasHeader: false, normalizer: ng)!;
      expect((m.phone, m.name, m.email), (0, 1, 2));
    });
    test('unknown headers: still guessed from the contents', () {
      final t = [['col1', 'col2'], ['Ada', '08031234567'], ['Bola', '08059990000']];
      final m = ColumnMapping.guess(t, hasHeader: true, normalizer: ng)!;
      expect((m.phone, m.name), (1, 0));
    });
    test('nothing looks like phone numbers', () =>
        expect(ColumnMapping.guess([['a', 'b'], ['c', 'd']], hasHeader: true, normalizer: ng), isNull));
  });

  group('planImport', () {
    test('first + last name columns are joined', () {
      final plan = planImport(
        table: [['Surname', 'Other names', 'GSM'], ['Lovelace', 'Ada', '08031234567'], ['', 'Grace', '08059990000']],
        mapping: const ColumnMapping(firstName: 1, lastName: 0, phone: 2),
        normalizer: ng, existingNormalized: {},
      );
      expect(plan.importable.map((r) => r.name), ['Ada Lovelace', 'Grace']);
    });
    test('two numbers in one cell: the first is used and flagged', () {
      final plan = planImport(table: [['name', 'phone'], ['Ada', '08031234567, 08051234567']],
          mapping: const ColumnMapping(name: 0, phone: 1), normalizer: ng, existingNormalized: {});
      expect(plan.importable.single.e164, '+2348031234567');
      expect(plan.multiNumberCount, 1);
    });
    test('no header row: the first row is imported too', () {
      final plan = planImport(table: [['Ada', '08031234567'], ['Bola', '08059990000']],
          mapping: const ColumnMapping(name: 0, phone: 1), normalizer: ng, existingNormalized: {}, hasHeader: false);
      expect(plan.valid, 2);
      expect(plan.importable.first.line, 1);
    });
    test('missing names: skipped, or named by number when asked', () {
      final t = [['name', 'phone'], ['', '08031234567']];
      const m = ColumnMapping(name: 0, phone: 1);
      expect(planImport(table: t, mapping: m, normalizer: ng, existingNormalized: {}).missingNames, 1);
      final p = planImport(table: t, mapping: m, normalizer: ng, existingNormalized: {}, useNumberAsName: true);
      expect(p.importable.single.name, '08031234567');
    });
    test('skipped rows keep their line numbers and reasons', () {
      final plan = planImport(
        table: [['name', 'phone'], ['Ada', '08031234567'], ['Ada again', '0803 123 4567'], ['Bad', '12'], ['Old', '08059990000']],
        mapping: const ColumnMapping(name: 0, phone: 1), normalizer: ng, existingNormalized: {'+2348059990000'},
      );
      expect(plan.skipped.map((r) => (r.line, r.status)),
          [(3, ImportRowStatus.duplicateInFile), (4, ImportRowStatus.invalidPhone)]);
      expect(plan.existing.single.line, 5);
    });
  });

  group('commitImportToGroup', () {
    late Database db;
    late ContactRepository repo;
    late GroupRepository groups;
    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      repo = ContactRepository(db);
      groups = GroupRepository(db);
    });
    tearDown(() => db.close());

    ImportPlan plan(Set<String> existing) => planImport(
          table: [['name', 'phone'], ['Ada', '08031234567'], ['Old friend', '08059990000']],
          mapping: const ColumnMapping(name: 0, phone: 1), normalizer: ng, existingNormalized: existing);

    test('new group: new and existing contacts both end up in it', () async {
      await repo.add(const Contact(name: 'Saved', phoneRaw: '0805', phoneNormalized: '+2348059990000'));
      final res = await repo.commitImportToGroup(plan(await repo.existingNormalized()), newGroupName: 'Choir');
      expect(res.added, 1);
      expect(res.inGroup, 2);
      final g = (await groups.list()).single;
      expect(g.name, 'Choir');
      expect((await groups.members(g.id)).map((c) => c.name).toSet(), {'Ada', 'Saved'});
      expect(await repo.count(), 2);
    });

    test('existing group, no new contacts: existing ones are still added', () async {
      await repo.add(const Contact(name: 'A', phoneRaw: '0803', phoneNormalized: '+2348031234567'));
      await repo.add(const Contact(name: 'B', phoneRaw: '0805', phoneNormalized: '+2348059990000'));
      final gid = await groups.create('Youth');
      final res = await repo.commitImportToGroup(plan(await repo.existingNormalized()), groupId: gid);
      expect((res.added, res.inGroup), (0, 2));
    });

    test('all or nothing: a failure saves no contacts and no new group', () async {
      const clash = ImportPlan([
        ImportRow(line: 2, name: 'One', phoneRaw: 'a', e164: '+2348031234567', status: ImportRowStatus.valid),
        ImportRow(line: 3, name: 'Two', phoneRaw: 'b', e164: '+2348031234567', status: ImportRowStatus.valid),
      ], 0);
      await expectLater(repo.commitImportToGroup(clash, newGroupName: 'Ghost'), throwsA(anything));
      expect(await repo.count(), 0);
      expect(await groups.list(), isEmpty);
    });
  });
}
