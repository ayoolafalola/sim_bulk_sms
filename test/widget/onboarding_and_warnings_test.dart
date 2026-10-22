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
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/platform/background/background_send_service.dart';
import 'package:sim_bulk_sms/platform/contacts/phone_contacts_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

class _Contacts implements PhoneContactsService {
  @override Future<bool> hasPermission() async => false;
  @override Future<bool> requestPermission() async => false;
  @override Future<List<PhoneContact>> load() async => const [];
}

void main() {
  sqfliteFfiInit();
  late Database db;

  Future<void> openDb(WidgetTester t, {bool onboarded = false}) async {
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      if (onboarded) await SettingsRepository(db).setFlag('onboarding_done', true);
    });
    addTearDown(() => t.runAsync(db.close));
  }

  Future<void> app(WidgetTester t, FakeBackground bg, {FakeMessagesApp? messages, FakeMessagesService? inbox}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final sms = FakeSmsService(androidFallback, bg: bg);
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backgroundSendServiceProvider.overrideWithValue(bg),
        smsServiceProvider.overrideWithValue(sms),
        capabilitiesProvider.overrideWith((ref) async => androidFallback),
        messagesAppProvider.overrideWithValue(messages ?? FakeMessagesApp()),
        messagesServiceProvider.overrideWithValue(inbox ?? FakeMessagesService(isDefaultApp: bg.current.defaultSms, bg: bg)),
        phoneContactsServiceProvider.overrideWithValue(_Contacts()),
      ],
      child: const SimBulkSmsApp(), // the real app, including its return-to-app checks
    ));
  }

  Future<void> settle(WidgetTester t, {Finder? until}) async {
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 200));
      if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
    }
  }

  testWidgets('fresh install: setup flow, skip what you like, reminded on the dashboard', (t) async {
    await openDb(t);
    final bg = FakeBackground(nothingGranted);
    await app(t, bg);
    appRouter.go('/');
    await settle(t, until: find.text('Welcome to Comeriver Messages'));
    expect(find.text('Welcome to Comeriver Messages'), findsOneWidget);

    await t.tap(find.text('Get started'));
    await settle(t, until: find.text('Default messaging app'));
    expect(find.text('Skip for now'), findsOneWidget);
    expect(find.textContaining('keep reminding you'), findsOneWidget);
    await t.ensureVisible(find.text('Make default'));
    await t.pump();
    await t.tap(find.text('Make default'));
    await settle(t, until: find.text('On'));
    expect(find.text('On'), findsOneWidget);
    await t.tap(find.text('Next'));
    await settle(t, until: find.text('Notifications'));

    // Skip notifications, alarms, battery; contacts is optional.
    for (final title in ['Alarms & reminders', 'Battery: Unrestricted', 'Contacts (optional)', 'Your country']) {
      await t.tap(find.text('Skip for now'));
      await settle(t, until: find.text(title));
      expect(find.text(title), findsWidgets);
    }
    expect(find.text('NG (+234)'), findsWidgets);
    await t.tap(find.text('Next'));
    await settle(t, until: find.text('Almost there'));
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Default messaging app'), findsNothing); // done during setup

    await t.tap(find.text('Start using the app'));
    await settle(t, until: find.text('Fix now'));
    expect(await t.runAsync(() => SettingsRepository(db).flag('onboarding_done')), true);
    expect(find.text('3 required permissions are off'), findsOneWidget);
    expect(find.textContaining('Scheduled runs only start while the app is open.'), findsWidgets);

    // Granting the rest (as if done in system settings) clears the warning on the next check.
    bg.current = everythingGranted;
    // Leave the app and come back (lifecycle steps in Flutter's allowed order).
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused,
      AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await settle(t);
    await settle(t);
    expect(find.text('Fix now'), findsNothing);
  });

  testWidgets('App setup checklist: refused-for-good contacts opens app settings', (t) async {
    await openDb(t, onboarded: true);
    final bg = FakeBackground(const BackgroundStatus(notifications: false, exactAlarms: true,
        batteryUnrestricted: true, serviceRunning: false, contacts: false, contactsPermanentlyDenied: true));
    await app(t, bg);
    appRouter.go('/settings/setup');
    await settle(t, until: find.text('Open app settings'));
    expect(find.textContaining('1 required item is missing'), findsOneWidget); // notifications
    await t.scrollUntilVisible(find.text('Open app settings'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('won\'t ask again'), findsOneWidget);
    await t.ensureVisible(find.text('Open app settings'));
    await t.pump();
    await t.tap(find.text('Open app settings'));
    await settle(t);
    expect(bg.opened, ['app']);
  });

  testWidgets('not the default messaging app: Messages tab offers to become default', (t) async {
    await openDb(t, onboarded: true);
    final bg = FakeBackground(everythingGranted);
    final inbox = FakeMessagesService(isDefaultApp: false, bg: bg);
    await app(t, bg, inbox: inbox);
    appRouter.go('/messages');
    await settle(t, until: find.text('Make default messaging app'));
    expect(find.text('Your texts, here'), findsOneWidget);
    inbox.receive(1, '+2348031234567', 'Hello');
    await t.tap(find.text('Make default messaging app'));
    await settle(t, until: find.text('Hello'));
    expect(find.text('+2348031234567'), findsOneWidget);
  });

  testWidgets('SMS off: messages go through the Messages app, one confirmed tap each', (t) async {
    await openDb(t, onboarded: true);
    late int id;
    await t.runAsync(() async {
      final repo = CampaignRepository(db);
      id = await repo.createDraft(name: 'Choir', template: 'Hi', platform: 'android');
      await repo.saveSnapshot(id, const [
        SnapshotRecipient(name: 'Ada', phoneE164: '+2341', renderedMessage: 'Hi Ada'),
        SnapshotRecipient(name: 'Bola', phoneE164: '+2342', renderedMessage: 'Hi Bola'),
      ]);
    });
    final messages = FakeMessagesApp();
    await app(t, FakeBackground(nothingGranted), messages: messages);
    appRouter.go('/campaigns/$id');
    await settle(t, until: find.text('Open next message (1 of 2)'));
    expect(find.textContaining('Messages open in your Messages app instead'), findsWidgets);
    expect(find.text('Turn on automatic sending'), findsOneWidget);

    await t.tap(find.text('Open next message (1 of 2)'));
    await settle(t, until: find.text('Start'));
    await t.tap(find.text('Start'));
    await settle(t, until: find.text('Did you send it to Ada?'));
    expect(messages.opened, [('+2341', 'Hi Ada')]);
    await t.tap(find.text('Sent'));
    await settle(t, until: find.text('Open next message (2 of 2)'));

    await t.tap(find.text('Open next message (2 of 2)'));
    await settle(t, until: find.text('Did you send it to Bola?'));
    await t.tap(find.text('Not sent'));
    await settle(t, until: find.text('Send again'));
    final counts = (await t.runAsync(() => CampaignRepository(db).statusCounts(id)))!;
    expect(counts, {RecipientStatus.sent: 1, RecipientStatus.cancelled: 1});
  });
}
