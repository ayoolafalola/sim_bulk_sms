import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/features/contacts/csv_import_screen.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

void main() {
  sqfliteFfiInit();

  testWidgets('register file: columns detected, preview, new group, import', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    late Database db;
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true); // past first-launch setup
      await ContactRepository(db)
          .add(const Contact(name: 'Already saved', phoneRaw: '0805', phoneNormalized: '+2348059990000'));
    });
    addTearDown(() => t.runAsync(db.close));

    Future<void> settle({Finder? until}) async {
      for (var i = 0; i < 80; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await t.pump(const Duration(milliseconds: 200));
        if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
      }
    }

    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    appRouter.go('/contacts');
    await settle();
    appRouter.push('/contacts/import-csv', extra: const CsvImportArgs(fileName: 'register.csv', text:
        'Surname;Other Names;GSM No.\n'
        'Lovelace;Ada;08031234567\n'
        'Babbage;Charles;0805 999 0000\n'
        'Hopper;Grace;12\n'));
    await settle(until: find.textContaining('Will import', skipOffstage: false));

    expect(find.text('3 rows · columns separated by semicolons'), findsOneWidget);
    expect(t.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'First row is headers')).value, true);
    expect(t.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'First and last names are in separate columns')).value, true);
    expect(find.text('Will import 1 new', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('1 already in your contacts', skipOffstage: false), findsOneWidget);
    expect(find.text('Ada Lovelace', skipOffstage: false), findsOneWidget);
    expect(find.text('+2348031234567', skipOffstage: false), findsOneWidget);
    expect(find.text('See skipped rows (1)', skipOffstage: false), findsOneWidget);

    // Add everyone to a new group.
    await t.scrollUntilVisible(find.text('No group'), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('No group'));
    await t.pumpAndSettle();
    await t.tap(find.text('New group…').last);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Choir');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('Import 1 contact into Choir'), findsOneWidget);
    expect(find.textContaining('already in your contacts are added to the group too'), findsOneWidget);

    await t.tap(find.text('Import 1 contact into Choir'));
    await settle(until: find.text('Choir'));
    final g = (await t.runAsync(() => GroupRepository(db).list()))!.single;
    final members = (await t.runAsync(() => GroupRepository(db).members(g.id)))!;
    expect(members.map((c) => c.name).toSet(), {'Ada Lovelace', 'Already saved'});
    expect(find.textContaining('Imported 1 new contact. 2 are now in the group.'), findsOneWidget);
  });

  testWidgets('file without a header row: switch is off and the first row is imported', (t) async {
    late Database db;
    await t.runAsync(() async => db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath));
    addTearDown(() => t.runAsync(db.close));
    await t.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: CsvImportScreen(args: CsvImportArgs(fileName: 'n.csv',
          text: 'Ada,08031234567\nBola,08059990000\n'))),
    ));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(t.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'First row is headers')).value, false);
    expect(find.text('Will import 2 new', skipOffstage: false), findsOneWidget);
  });

  testWidgets('too many rows: asks to split the file', (t) async {
    late Database db;
    await t.runAsync(() async => db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath));
    addTearDown(() => t.runAsync(db.close));
    final big = StringBuffer('name,phone\n');
    for (var i = 0; i < maxImportRows + 5; i++) {
      big.writeln('P$i,0803${(1000000 + i)}');
    }
    await t.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: CsvImportScreen(args: CsvImportArgs(fileName: 'big.csv', text: big.toString()))),
    ));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('split the file'), findsOneWidget);
  });
}
