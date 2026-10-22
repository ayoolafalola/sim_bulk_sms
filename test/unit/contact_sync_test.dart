import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/core/phone_numbers/phone_normalizer.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/sync/contact_sync.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/platform/contacts/phone_contacts_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const ada = SyncedContact(
  contactId: 1, lookupKey: 'L1', name: 'Ada Okafor', givenName: 'Ada', familyName: 'Okafor',
  phones: [
    SyncedValue(value: '0803 123 4567', label: 'Work', type: 3),
    SyncedValue(value: '0805 123 4567', label: 'Mobile', type: 2),
  ],
  emails: [SyncedValue(value: 'ada@example.com', label: 'Home')],
  dates: [SyncedValue(value: '1990-05-17', kind: 'birthday', label: 'Birthday')],
  organization: 'Comeriver', jobTitle: 'Engineer', address: '1 Marina, Lagos', note: 'Choir lead',
);

void main() {
  sqfliteFfiInit();
  late Database db;
  late ContactRepository repo;
  late ContactSync sync;

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    repo = ContactRepository(db);
    sync = ContactSync(db, PhoneNormalizer('NG'));
  });
  tearDown(() => db.close());

  test('first sync brings in the phone format; texts go to the Mobile number', () async {
    final r = await sync.apply(const ContactsSnapshot(contacts: [ada], now: 10, full: true));
    expect(r.added, 1);
    final c = (await repo.search()).single;
    expect(c.source, ContactSource.phone);
    expect(c.phoneNormalized, '+2348051234567'); // Mobile wins over Work
    expect(c.email, 'ada@example.com');
    expect(c.organization, 'Comeriver');
    expect(c.birthday, '1990-05-17');
    final d = (await repo.details(c.id!))!;
    expect(d.phones, hasLength(2));
    expect(d.dates.single.kind, 'birthday');
  });

  test('contacts with neither a number nor an email are skipped', () async {
    final r = await sync.apply(const ContactsSnapshot(
        contacts: [SyncedContact(contactId: 2, lookupKey: 'L2', name: 'Just a name')], now: 10, full: true));
    expect(r.added, 0);
    expect(await repo.count(), 0);
  });

  test('changes update the same contact; deleted on the phone means removed here', () async {
    await sync.apply(const ContactsSnapshot(contacts: [ada], now: 10, full: true));
    final id = (await repo.search()).single.id!;
    await sync.apply(const ContactsSnapshot(contacts: [
      SyncedContact(contactId: 1, lookupKey: 'L1', name: 'Ada O.', phones: [SyncedValue(value: '08051234567', type: 2)]),
    ], now: 20, full: false));
    final c = (await repo.search()).single;
    expect(c.id, id);
    expect(c.name, 'Ada O.');

    final r = await sync.apply(const ContactsSnapshot(contacts: [], deleted: [1], now: 30, full: false));
    expect(r.removed, 1);
    expect(await repo.count(), 0);
  });

  test('a full sync removes phone contacts no longer on the phone but keeps app contacts', () async {
    await repo.add(const Contact(name: 'From a file', phoneRaw: '0809', phoneNormalized: '+2348091234567'));
    await sync.apply(const ContactsSnapshot(contacts: [ada], now: 10, full: true));
    await sync.apply(const ContactsSnapshot(contacts: [], now: 20, full: true));
    final left = await repo.search();
    expect(left.map((c) => c.name), ['From a file']);
    expect(left.single.source, ContactSource.app);
  });

  test('an app contact with the same number becomes the phone contact, keeping consent and groups', () async {
    final appId = await repo.add(const Contact(name: 'Ada (old)', phoneRaw: '0805', phoneNormalized: '+2348051234567'));
    await repo.setConsent(appId, ConsentStatus.optedIn);
    final groups = GroupRepository(db);
    final g = await groups.create('Choir');
    await groups.addContacts(g, [appId]);

    await sync.apply(const ContactsSnapshot(contacts: [ada], now: 10, full: true));
    final c = (await repo.search()).single;
    expect(c.id, appId);
    expect(c.name, 'Ada Okafor');
    expect(c.source, ContactSource.phone);
    expect(c.consent, ConsentStatus.optedIn);
    expect(await groups.groupNamesOf(appId), ['Choir']);
  });

  test('the number and email chosen in the app survive later syncs', () async {
    await sync.apply(const ContactsSnapshot(contacts: [ada], now: 10, full: true));
    final id = (await repo.search()).single.id!;
    final work = (await repo.details(id))!.phones.firstWhere((p) => p.label == 'Work');
    await repo.preferPhone(id, work);
    await sync.apply(const ContactsSnapshot(contacts: [ada], now: 20, full: false));
    expect((await repo.get(id))!.phoneNormalized, '+2348031234567');
    expect((await repo.findByE164('+2348051234567'))?.id, id); // the other number still finds them
  });

  test('two phone contacts may share a number; app-added numbers stay unique', () async {
    await sync.apply(const ContactsSnapshot(contacts: [
      ada,
      SyncedContact(contactId: 3, lookupKey: 'L3', name: 'Ada (work phone)', phones: [SyncedValue(value: '08051234567')]),
    ], now: 10, full: true));
    expect(await repo.count(), 2);
    await repo.add(const Contact(name: 'Bayo', phoneRaw: '0806', phoneNormalized: '+2348061234567'));
    await expectLater(
        repo.add(const Contact(name: 'Bayo again', phoneRaw: '0806', phoneNormalized: '+2348061234567')),
        throwsA(isA<DuplicateContactException>()));
  });
}
