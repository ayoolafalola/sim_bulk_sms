import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/app.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/app/sending_providers.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/platform/messages/messages_service.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

void main() {
  sqfliteFfiInit();
  late Database db;
  late FakeMessagesService inbox;

  Future<void> start(WidgetTester t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true);
    });
    addTearDown(() => t.runAsync(db.close));
    inbox = FakeMessagesService()
      ..receive(1, '+2348031234567', 'Thank you! See you on Sunday', at: DateTime.now().subtract(const Duration(minutes: 5)))
      ..receive(2, '+2348059990000', 'Please add my wife too', at: DateTime.now().subtract(const Duration(hours: 1)))
      ..names[1] = 'Ada Okafor';
    inbox.readThreads.add(2); // already read
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        messagesServiceProvider.overrideWithValue(inbox),
        backgroundSendServiceProvider.overrideWithValue(FakeBackground(everythingGranted)),
        smsServiceProvider.overrideWithValue(FakeSmsService(androidOk)),
      ],
      child: const SimBulkSmsApp(),
    ));
    appRouter.go('/messages');
  }

  Future<void> settle(WidgetTester t, {Finder? until}) async {
    for (var i = 0; i < 80; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 200));
      if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
    }
  }

  testWidgets('inbox: conversations newest first, names, unread counts, unread badge on the tab', (t) async {
    await start(t);
    await settle(t, until: find.text('Ada Okafor'));
    expect(find.text('Ada Okafor'), findsOneWidget);
    expect(find.text('+2348059990000'), findsOneWidget);
    expect(t.getTopLeft(find.text('Ada Okafor')).dy, lessThan(t.getTopLeft(find.text('+2348059990000')).dy));
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.text('1')), findsOneWidget);

    await t.tap(find.text('Unread'));
    await t.pump();
    expect(find.text('+2348059990000'), findsNothing);

    await t.tap(find.text('All'));
    await t.enterText(find.byType(TextField).first, 'wife');
    await t.pump();
    expect(find.text('Ada Okafor'), findsNothing);
    expect(find.text('+2348059990000'), findsOneWidget);
  });

  testWidgets('conversation: opening marks it read; replying sends and shows it', (t) async {
    await start(t);
    await settle(t, until: find.text('Ada Okafor'));
    await t.tap(find.text('Ada Okafor'));
    await settle(t, until: find.text('Thank you! See you on Sunday'));
    expect(inbox.readThreads, contains(1));

    await t.enterText(find.widgetWithText(TextField, 'Text message'), 'You\'re welcome');
    await t.tap(find.byTooltip('Send'));
    await settle(t, until: find.text('You\'re welcome'));
    expect(inbox.sent, [('+2348031234567', 'You\'re welcome')]);
    expect(find.textContaining('Sent'), findsWidgets);

    await t.tap(find.text('See you there')); // quick reply
    await settle(t, until: find.text('See you there').last);
    expect(inbox.sent.last, ('+2348031234567', 'See you there'));
  });

  testWidgets('opened from a notification: goes straight to that conversation', (t) async {
    await start(t);
    await settle(t, until: find.byType(NavigationBar)); // inbox up first
    inbox.open(const LaunchRequest(threadId: 2));
    await settle(t, until: find.byTooltip('Send'));
    expect(find.text('Please add my wife too'), findsWidgets);
    expect(find.byType(NavigationBar), findsNothing); // full-screen conversation
  });

  testWidgets('another app asked to text a number: conversation opens with the draft', (t) async {
    await start(t);
    await settle(t, until: find.byType(NavigationBar));
    inbox.open(const LaunchRequest(address: '+2348077777777', body: 'Hello from Contacts'));
    await settle(t, until: find.byTooltip('Send'));
    expect(find.widgetWithText(TextField, 'Hello from Contacts'), findsOneWidget);
    expect(find.text('+2348077777777'), findsWidgets);
  });
}
