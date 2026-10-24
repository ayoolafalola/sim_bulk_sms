import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/app.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/app/sending_providers.dart';
import 'package:sim_bulk_sms/core/phone_numbers/phone_normalizer.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/data/sync/contact_sync.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/platform/contacts/phone_contacts_service.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

const ada = SyncedContact(
  contactId: 1, lookupKey: 'L1', name: 'Ada Okafor',
  phones: [
    SyncedValue(value: '0805 123 4567', label: 'Mobile', type: 2),
    SyncedValue(value: '0803 123 4567', label: 'Work', type: 3),
  ],
  dates: [SyncedValue(value: '1990-05-17', kind: 'birthday', label: 'Birthday')],
  organization: 'Comeriver',
);
const bola = SyncedContact(contactId: 2, lookupKey: 'L2', name: 'Bola Ade', phones: [SyncedValue(value: '0701 222 3333')]);

void main() {
  sqfliteFfiInit();
  late Database db;
  late FakePhoneContactsBase phone;

  Future<void> settle(WidgetTester t, {Finder? until}) async {
    for (var i = 0; i < 80; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 200));
      if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
    }
  }

  /// [synced]: sync already on, with Ada and Bola in.
  Future<void> start(WidgetTester t, {bool synced = false}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    phone = FakePhoneContactsBase()..snapshot = const ContactsSnapshot(contacts: [ada, bola], now: 10, full: true);
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true);
      if (synced) {
        await SettingsRepository(db).setContactsSync(true);
        await ContactSync(db, PhoneNormalizer('NG')).apply(phone.snapshot);
        await SettingsRepository(db).setContactsSyncedAt(10);
      }
    });
    addTearDown(() => t.runAsync(db.close));
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        backgroundSendServiceProvider.overrideWithValue(null),
        smsServiceProvider.overrideWithValue(FakeSmsService(androidOk)),
        phoneContactsServiceProvider.overrideWithValue(phone),
      ],
      child: const SimBulkSmsApp(),
    ));
    appRouter.go('/contacts');
  }

  testWidgets('asks before using phone contacts; yes brings them in and Settings shows sync', (t) async {
    await start(t);
    await settle(t, until: find.text('Use phone contacts'));
    expect(find.text('From phone'), findsOneWidget); // not synced yet: the one-off import is offered
    expect(phone.syncedSince, isEmpty); // nothing read before the user says yes

    await t.tap(find.text('Use phone contacts'));
    await settle(t, until: find.text('Ada Okafor'));
    expect(find.text('Bola Ade'), findsOneWidget);
    expect(find.text('Use phone contacts'), findsNothing);
    expect(find.text('From phone'), findsNothing);
    expect(await t.runAsync(() => SettingsRepository(db).contactsSync()), true);

    appRouter.go('/settings');
    await settle(t, until: find.text('Sync phone contacts'));
    expect(find.textContaining('2 from your phone'), findsOneWidget);
  });

  testWidgets('"Not now" hides the question and syncs nothing', (t) async {
    await start(t);
    await settle(t, until: find.text('Not now'));
    await t.tap(find.text('Not now'));
    await settle(t);
    expect(find.text('Use phone contacts'), findsNothing);
    expect(phone.syncedSince, isEmpty);
    expect(await t.runAsync(() => SettingsRepository(db).contactsSync()), false);
  });

  testWidgets('contact screen: details, edit in the Contacts app, choose the number for texts', (t) async {
    await start(t, synced: true);
    await settle(t, until: find.text('Ada Okafor'));
    await t.tap(find.text('AO'));
    await settle(t, until: find.text('From your phone'));
    expect(find.text('Comeriver'), findsOneWidget);
    expect(find.text('17 May 1990'), findsOneWidget);
    expect(find.text('Delete contact'), findsNothing); // phone contacts are deleted on the phone

    await t.tap(find.byTooltip('Edit'));
    await settle(t);
    expect(phone.edited.single.name, 'Ada Okafor');

    await t.tap(find.text('0803 123 4567'));
    await settle(t);
    final id = (await t.runAsync(() => ContactRepository(db).search('Ada')))!.single.id!;
    expect((await t.runAsync(() => ContactRepository(db).get(id)))!.phoneNormalized, '+2348031234567');
  });

  testWidgets('select several, select all, add them to a group', (t) async {
    late int groupId;
    await start(t, synced: true);
    await t.runAsync(() async => groupId = await GroupRepository(db).create('Choir'));
    await settle(t, until: find.text('Ada Okafor'));
    await t.longPress(find.text('AO'));
    await settle(t, until: find.text('1 selected'));
    await t.tap(find.text('Select all'));
    await settle(t, until: find.text('2 selected'));
    await t.tap(find.text('Add to group'));
    await settle(t, until: find.text('Choir'));
    await t.tap(find.text('Choir'));
    await settle(t, until: find.textContaining('Added 2 people'));
    expect(find.text('Contacts'), findsWidgets); // back out of select mode
    final members = await t.runAsync(() => GroupRepository(db).members(groupId));
    expect(members!.map((c) => c.name).toSet(), {'Ada Okafor', 'Bola Ade'});
    expect(members.every((c) => c.source == ContactSource.phone), true);
  });
}
