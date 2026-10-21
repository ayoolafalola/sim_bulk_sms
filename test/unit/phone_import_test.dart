import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/features/contacts/import_phone_contacts_screen.dart';
import 'package:sim_bulk_sms/platform/contacts/phone_contacts_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('filterPhoneContacts', () {
    const all = [
      PhoneContact(name: 'Ada Lovelace', phone: '+234 803 123 4567'),
      PhoneContact(name: 'Bola Church', phone: '0805-999-0000'),
      PhoneContact(name: 'Church Office', phone: '(0701) 222 3333'),
    ];
    test('empty query shows everyone', () => expect(filterPhoneContacts(all, '  '), [0, 1, 2]));
    test('name match is case-insensitive', () => expect(filterPhoneContacts(all, 'church'), [1, 2]));
    test('number match ignores formatting', () => expect(filterPhoneContacts(all, '999 0000'), [1]));
    test('local 0803 finds +234 803', () => expect(filterPhoneContacts(all, '0803'), [0]));
    test('a short query keeps its leading 0', () => expect(filterPhoneContacts(all, '08'), [1]));
  });

  group('ContactRepository.upsertByPhone', () {
    late Database db;
    late ContactRepository repo;
    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      repo = ContactRepository(db);
    });
    tearDown(() => db.close());

    test('adds new numbers, reuses existing ones, ignores repeats in the input', () async {
      final existing = await repo.add(const Contact(
          name: 'Ada (saved)', phoneRaw: '0803', phoneNormalized: '+2348031234567', consent: ConsentStatus.optedIn));
      final r = await repo.upsertByPhone([
        (name: 'Ada', phoneRaw: '+234 803 123 4567', e164: '+2348031234567'),
        (name: 'Bola', phoneRaw: '0805 999 0000', e164: '+2348059990000'),
        (name: 'Bola again', phoneRaw: '08059990000', e164: '+2348059990000'),
        (name: '', phoneRaw: '0701 222 3333', e164: '+2347012223333'),
      ]);
      expect(r.added, 2);
      expect(r.existing, 1);
      expect(r.ids, hasLength(3));
      expect(r.ids.first, existing);
      final all = await repo.search();
      expect(all, hasLength(3));
      final ada = all.firstWhere((c) => c.id == existing);
      expect(ada.name, 'Ada (saved)'); // existing contact left alone
      expect(ada.consent, ConsentStatus.optedIn);
      expect(all.map((c) => c.name), contains('+2347012223333')); // blank name falls back to number
    });
  });
}
