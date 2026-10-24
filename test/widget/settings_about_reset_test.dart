import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/app.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/app/sending_providers.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

void main() {
  sqfliteFfiInit();

  testWidgets('Settings › About links, and Reset app (type RESET) starts over at the welcome screen', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    late Database db;
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true);
      await SettingsRepository(db).setContactsSync(false);
      await GroupRepository(db).create('Choir');
    });
    addTearDown(() => t.runAsync(db.close));
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        backgroundSendServiceProvider.overrideWithValue(FakeBackground(everythingGranted)),
        smsServiceProvider.overrideWithValue(FakeSmsService(androidOk)),
      ],
      child: const SimBulkSmsApp(),
    ));
    Future<void> settle({Finder? until}) async {
      for (var i = 0; i < 80; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await t.pump(const Duration(milliseconds: 200));
        if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
      }
    }

    appRouter.go('/settings');
    await settle(until: find.text('Settings'));
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    await t.scrollUntilVisible(find.text('Reset app…'), 200, scrollable: list);
    for (final row in ['Share Messages++', 'Website', 'Privacy policy', 'Terms of use', 'Contact support', 'Made by Comeriver']) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    expect(find.text('Messages++ by Comeriver · version 1.0.0'), findsOneWidget);

    await t.tap(find.text('Reset app…'));
    await settle(until: find.text('Reset Messages++?'));
    final reset = find.widgetWithText(FilledButton, 'Reset');
    expect(t.widget<FilledButton>(reset).onPressed, isNull); // not until RESET is typed
    await t.enterText(find.byType(TextField).last, 'reset');
    await t.pump();
    await t.tap(reset);
    await settle(until: find.text('Welcome to Messages++'));
    expect(find.text('Welcome to Messages++'), findsOneWidget);
    expect(await t.runAsync(() => GroupRepository(db).count()), 0);
  });
}
