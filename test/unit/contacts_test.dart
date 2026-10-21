import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/core/phone_numbers/phone_normalizer.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/importers/contact_import_planner.dart';
import 'package:sim_bulk_sms/data/importers/csv_parser.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/recipient_eligibility.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show Database;

void main() {
  sqfliteFfiInit();

  group('PhoneNormalizer (NG)', () {
    final n = PhoneNormalizer('NG');
    test('local format uses default region and flags it', () {
      final r = n.normalize('0803 123 4567');
      expect(r.e164, '+2348031234567');
      expect(r.regionAssumed, true);
    });
    test('international format is not flagged', () {
      final r = n.normalize('+2348031234567');
      expect([r.e164, r.regionAssumed], ['+2348031234567', false]);
    });
    test('00 prefix treated as international', () => expect(n.normalize('002348031234567').e164, '+2348031234567'));
    test('garbage is invalid', () => expect(n.normalize('abc').isValid, false));
    test('empty reported as empty', () => expect(n.normalize('  ').status, PhoneParseStatus.empty));
    test('unknown region throws', () => expect(() => PhoneNormalizer('ZZ'), throwsArgumentError));
  });

  group('parseCsv', () {
    test('basic + BOM + CRLF', () =>
        expect(parseCsv('\uFEFFname,phone\r\nAda,0803\r\n'), [['name', 'phone'], ['Ada', '0803']]));
    test('quotes, commas, escaped quotes, newline in field', () =>
        expect(parseCsv('a,b\n"Doe, J ""JD""","x\ny"\n'), [['a', 'b'], ['Doe, J "JD"', 'x\ny']]));
    test('semicolon delimiter', () => expect(parseCsv('name;phone\nAda;1'), [['name', 'phone'], ['Ada', '1']]));
    test('blank lines dropped', () => expect(parseCsv('a,b\n\n\n1,2\n').length, 2));
    test('unterminated quote throws', () => expect(() => parseCsv('a,b\n"oops,1'), throwsA(isA<CsvFormatException>())));
    test('unicode preserved', () => expect(parseCsv('name,phone\nÒlá,1')[1][0], 'Òlá'));
  });

  group('planImport', () {
    final norm = PhoneNormalizer('NG');
    final table = parseCsv('Name,Mobile,E-mail\n'
        'Ada,08031234567,a@x.com\n'
        'Ada Again,+2348031234567,\n'     // dup in file
        'Bob,not a number,\n'             // invalid
        ',08051234567,\n'                 // missing name
        'Cy,08061234567,\n'               // dup existing
        ',,\n');                          // blank
    test('header mapping is suggested', () {
      final m = ColumnMapping.suggest(table.first)!;
      expect([m.name, m.phone, m.email], [0, 1, 2]);
    });
    test('counts', () {
      final plan = planImport(table: table, mapping: ColumnMapping.suggest(table.first)!,
          normalizer: norm, existingNormalized: {'+2348061234567'});
      expect(plan.valid, 1);
      expect(plan.invalid, 2);
      expect(plan.duplicates, 2);
      expect(plan.skippedBlank, 1);
      expect(plan.regionAssumedCount, 1);
    });
    test('unknown headers -> null mapping', () => expect(ColumnMapping.suggest(['x', 'y']), isNull));
  });

  group('ContactRepository (in-memory SQLite)', () {
    late ContactRepository repo;
    late Database db;
    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      repo = ContactRepository(db);
    });
    tearDown(() => db.close());

    test('add, search, duplicate rejected', () async {
      await repo.add(const Contact(name: 'Ada', phoneRaw: '0803', phoneNormalized: '+2348031234567'));
      expect((await repo.search('ad')).length, 1);
      expect(() => repo.add(const Contact(name: 'X', phoneRaw: '1', phoneNormalized: '+2348031234567')),
          throwsA(isA<DuplicateContactException>()));
    });

    test('commitImport is atomic: a failure rolls everything back', () async {
      await repo.add(const Contact(name: 'Existing', phoneRaw: '1', phoneNormalized: '+2348031234567'));
      // Deliberately build a plan whose 2nd row collides with the existing contact.
      const plan = ImportPlan([
        ImportRow(line: 2, name: 'New', phoneRaw: 'a', e164: '+2348051234567', status: ImportRowStatus.valid),
        ImportRow(line: 3, name: 'Clash', phoneRaw: 'b', e164: '+2348031234567', status: ImportRowStatus.valid),
      ], 0);
      await expectLater(repo.commitImport(plan), throwsA(anything));
      expect(await repo.count(), 1);
    });

    test('imports 1,000 contacts', () async {
      final rows = [for (var i = 0; i < 1000; i++)
        ImportRow(line: i + 2, name: 'C$i', phoneRaw: '$i', e164: '+23480${(10000000 + i)}', status: ImportRowStatus.valid)];
      expect(await repo.commitImport(ImportPlan(rows, 0)), 1000);
      expect(await repo.count(), 1000);
    });

    test('consent + suppression filtering', () async {
      await repo.suppress('+2348031234567', reason: 'asked to stop');
      final sup = await repo.suppressedNumbers();
      final res = filterEligible(const [
        Contact(name: 'A', phoneRaw: '', phoneNormalized: '+2348031234567'),
        Contact(name: 'B', phoneRaw: '', phoneNormalized: '+2348051234567', consent: ConsentStatus.optedOut),
        Contact(name: 'C', phoneRaw: '', phoneNormalized: '+2348061234567'),
        Contact(name: 'D', phoneRaw: '', phoneNormalized: '+2348061234567'),
        Contact(name: 'E', phoneRaw: '', phoneNormalized: null),
      ], sup);
      expect(res.eligible.map((c) => c.name), ['C']);
      expect([res.excludedSuppressed.length, res.excludedOptedOut.length, res.excludedInvalid.length], [1, 1, 1]);
    });
  });
}
