import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/app.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/app/sending_providers.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

void main() {
  sqfliteFfiInit();
  late Database db;

  Future<void> start(WidgetTester t, {FakeBackground? bg}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true);
      await ContactRepository(db).add(const Contact(name: 'Ada Okafor', phoneRaw: '0803', phoneNormalized: '+2348031234567',
          email: 'ada@example.com'));
    });
    addTearDown(() => t.runAsync(db.close));
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        backgroundSendServiceProvider.overrideWithValue(bg),
        smsServiceProvider.overrideWithValue(FakeSmsService(androidOk)),
      ],
      child: const SimBulkSmsApp(),
    ));
    appRouter.go('/');
  }

  Future<void> settle(WidgetTester t, {Finder? until}) async {
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 200));
      if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
    }
  }

  testWidgets('bottom navigation switches tabs; Settings shows a dot while setup is incomplete', (t) async {
    await start(t, bg: FakeBackground(nothingGranted));
    await settle(t, until: find.text('No campaigns yet'));
    expect(find.byType(NavigationBar), findsOneWidget);
    // The Settings tab's badge (the last one; Messages has the unread badge).
    final badge = t.widget<Badge>(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)).last);
    expect(badge.isLabelVisible, true);

    await t.tap(find.text('Contacts').last);
    await settle(t, until: find.text('Ada Okafor'));
    expect(find.text('From phone'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget); // badge: this contact has an email

    await t.tap(find.text('Settings').last);
    await settle(t, until: find.text('Sending safely'.toUpperCase()));
    expect(find.text('4 missing'), findsOneWidget);
  });

  testWidgets('deleting a contact can be undone', (t) async {
    await start(t);
    appRouter.go('/contacts');
    await settle(t, until: find.text('Ada Okafor'));
    await t.tap(find.text('Ada Okafor'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle(); // the action sheet finishes closing
    expect(find.text('Ada Okafor'), findsNothing);
    expect(find.text('Deleted Ada Okafor'), findsOneWidget);
    await t.tap(find.text('Undo'));
    await settle(t, until: find.text('Ada Okafor'));
    expect(find.text('Ada Okafor'), findsOneWidget);
    expect(await t.runAsync(() => ContactRepository(db).count()), 1);
  });

  testWidgets('deleting a draft can be undone; without Undo it is really deleted', (t) async {
    await start(t);
    late int id;
    await t.runAsync(() async => id = await CampaignRepository(db).createDraft(name: 'Youth camp', template: 'x', platform: 'android'));
    appRouter.go('/campaigns/$id');
    await settle(t, until: find.byTooltip('Delete'));
    await t.tap(find.byTooltip('Delete'));
    await settle(t, until: find.text('Undo'));
    expect(find.text('Discard changes?'), findsNothing); // no confirmation dialog for drafts
    expect(find.textContaining('Deleted draft'), findsOneWidget);
    await t.tap(find.text('Undo'));
    await settle(t, until: find.text('Youth camp'));
    expect(await t.runAsync(() => CampaignRepository(db).get(id)), isNotNull);

    await t.tap(find.text('Youth camp')); // opens the editor (it's a draft)
    await settle(t, until: find.text('Edit campaign'));
    await t.pageBack();
    await settle(t);
    appRouter.go('/campaigns/$id');
    await settle(t, until: find.byTooltip('Delete'));
    await t.tap(find.byTooltip('Delete'));
    await settle(t, until: find.text('Undo'));
    ScaffoldMessenger.of(t.element(find.text('Undo'))).hideCurrentSnackBar();
    await settle(t);
    expect(await t.runAsync(() => CampaignRepository(db).get(id)), isNull);
  });
}
