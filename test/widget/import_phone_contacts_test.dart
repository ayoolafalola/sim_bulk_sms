import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/features/contacts/import_phone_contacts_screen.dart';
import 'package:sim_bulk_sms/platform/contacts/phone_contacts_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakePhoneContacts implements PhoneContactsService {
  FakePhoneContacts(this.contacts, {this.granted = true});
  final List<PhoneContact> contacts;
  bool granted;
  int requests = 0;
  @override Future<bool> hasPermission() async => granted;
  @override Future<bool> requestPermission() async { requests++; return granted; }
  @override Future<List<PhoneContact>> load() async => contacts;
}

const phone = [
  PhoneContact(name: 'Ada Church', phone: '+234 803 123 4567'),
  PhoneContact(name: 'Bola Church', phone: '0805 999 0000'),
  PhoneContact(name: 'Chidi', phone: '0701 222 3333'),
  PhoneContact(name: 'Broken Church', phone: '12'),
];

void main() {
  sqfliteFfiInit();

  testWidgets('permission denied explains and offers to ask again', (t) async {
    final fake = FakePhoneContacts(phone, granted: false);
    await t.pumpWidget(ProviderScope(
      overrides: [phoneContactsServiceProvider.overrideWithValue(fake)],
      child: const MaterialApp(home: ImportPhoneContactsScreen()),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('Contacts access is needed'), findsOneWidget);
    expect(fake.requests, 1);
    fake.granted = true;
    await t.tap(find.text('Allow access'));
    await t.pumpAndSettle();
    expect(find.text('Select all (4)'), findsOneWidget);
  });

  testWidgets('search, select all matches, add to the group', (t) async {
    late Database db;
    late int groupId;
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true); // past first-launch setup
      groupId = await GroupRepository(db).create('Church');
    });
    addTearDown(() => t.runAsync(db.close));

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        phoneContactsServiceProvider.overrideWithValue(FakePhoneContacts(phone)),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    appRouter.go('/groups/$groupId');
    await settle();
    appRouter.push('/contacts/import?group=$groupId');
    await settle();

    expect(find.text('Select all (4)'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'church');
    await t.pump();
    expect(find.text('Select all matches (3)'), findsOneWidget);
    expect(find.text('Chidi'), findsNothing);

    await t.tap(find.text('Select all matches (3)'));
    await t.pump();
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.text('Add 3 to group'), findsOneWidget);

    await t.tap(find.text('Add 3 to group'));
    await settle();

    final members = await t.runAsync(() => GroupRepository(db).members(groupId));
    expect(members!.map((c) => c.name).toSet(), {'Ada Church', 'Bola Church'}); // '12' is not a valid number
    expect(find.textContaining('skipped (invalid number): 1'), findsAtLeastNWidgets(1)); // may show on both screens mid-transition
    await t.pump(const Duration(seconds: 1)); // let the pop transition finish
    expect(find.text('Import from phone'), findsNothing); // returned to the group screen
    final saved = await t.runAsync(() => ContactRepository(db).count());
    expect(saved, 2);
  });
}
