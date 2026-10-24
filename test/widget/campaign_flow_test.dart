import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Drives the real router, editor and composer against an in-memory database.
void main() {
  sqfliteFfiInit();

  testWidgets('pick a group, write a message, save -> ready campaign', (t) async {
    late Database db;
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true); // past first-launch setup
      final contacts = ContactRepository(db);
      final g = await GroupRepository(db).create('Volunteers');
      await GroupRepository(db).addContacts(g, [
        await contacts.add(const Contact(name: 'Ada Lovelace', phoneRaw: '+2348012345678', phoneNormalized: '+2348012345678')),
        await contacts.add(const Contact(name: 'Bob', phoneRaw: '+2348012345679', phoneNormalized: '+2348012345679')),
      ]);
    });
    addTearDown(() => t.runAsync(db.close));

    // Real DB I/O happens outside the fake clock: let it finish, then rebuild.
    // With [until], keep going (bounded) until that widget shows up, so a slow
    // machine doesn't make the test flaky.
    Future<void> settle({Finder? until}) async {
      for (var i = 0; i < 80; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await t.pump(const Duration(milliseconds: 300));
        if (i >= 4 && (until == null || until.evaluate().isNotEmpty)) return;
      }
    }

    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => const SmsCapabilities(platform: SmsPlatform.android,
            canSendDirectly: true, usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none)),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    appRouter.go('/campaigns/new');
    await settle();

    await t.enterText(find.widgetWithText(TextField, 'Campaign name'), 'Launch');
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'Hi {first_name}, see you Saturday');
    await t.tap(find.text('Volunteers (2)'));
    await settle(until: find.text('2 recipients', skipOffstage: false));

    expect(find.text('2 recipients', skipOffstage: false), findsOneWidget);
    // The free app adds the signature to every campaign text.
    expect(find.text('Hi Ada, see you Saturday\nSent via messages.comeriver.com', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('have not confirmed consent', skipOffstage: false), findsOneWidget);

    await t.tap(find.text('Save and review'));
    await settle(until: find.text('Waiting: 2'));

    expect(find.text('Ready to send'), findsOneWidget);
    expect(find.text('Waiting: 2'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    final saved = await t.runAsync(() => CampaignRepository(db).recent());
    expect(saved!.single.status, CampaignStatus.ready);
    expect(GoRouter.of(t.element(find.text('Launch').first)).routeInformationProvider.value.uri.path, '/campaigns/${saved.single.id}');
  });
}
