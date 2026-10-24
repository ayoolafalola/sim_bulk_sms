import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/app.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/app/sending_providers.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/email_settings.dart';
import 'package:sim_bulk_sms/platform/email/email_sender.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

void main() {
  sqfliteFfiInit();
  late Database db;
  final requests = <String>[];

  Future<HttpReply> post(Uri url, Map<String, String> headers, List<int> body) async {
    requests.add('$url ${utf8.decode(body)}');
    return const HttpReply(200, '{"id":"<t@mg>"}');
  }

  Future<void> settle(WidgetTester t, {Finder? until}) async {
    for (var i = 0; i < 80; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 200));
      if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
    }
  }

  Future<void> start(WidgetTester t, String location, {double height = 2400}) async {
    t.view.physicalSize = Size(1080, height);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    requests.clear();
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true);
      await SettingsRepository(db).setContactsSync(false);
    });
    addTearDown(() => t.runAsync(db.close));
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        backgroundSendServiceProvider.overrideWithValue(null),
        smsServiceProvider.overrideWithValue(FakeSmsService(androidOk)),
        emailPostProvider.overrideWithValue(post),
      ],
      child: const SimBulkSmsApp(),
    ));
    appRouter.go(location);
  }

  testWidgets('set up the Mailgun API and send a test email', (t) async {
    await start(t, '/settings/email');
    await settle(t, until: find.text('Mailgun API'));
    await t.tap(find.text('Mailgun API'));
    await settle(t, until: find.text('Sending domain'));
    await t.enterText(find.widgetWithText(TextField, 'Sending domain'), 'mg.example.com');
    await t.enterText(find.widgetWithText(TextField, 'API key'), 'key-123');
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    await t.scrollUntilVisible(find.text('From address'), 150, scrollable: list);
    await t.enterText(find.widgetWithText(TextField, 'From address'), 'news@mg.example.com');
    await t.scrollUntilVisible(find.text('Send test email'), 150, scrollable: list);
    await t.drag(list, const Offset(0, -300)); // clear of the Save bar
    await t.pump();
    await t.tap(find.text('Send test email'));
    await settle(t, until: find.text('Send a test email to'));
    await t.tap(find.text('Send'));
    await settle(t, until: find.textContaining('Sent to news@mg.example.com'));
    expect(requests.single, startsWith('https://api.mailgun.net/v3/mg.example.com/messages'));
    final saved = await t.runAsync(() => SettingsRepository(db).loadEmail());
    expect((saved!.provider, saved.ready), (EmailProvider.mailgun, true));
  });

  testWidgets('Send by Email asks for a subject and previews the email', (t) async {
    await start(t, '/campaigns/new');
    await t.runAsync(() async {
      final id = await ContactRepository(db)
          .add(const Contact(name: 'Bola Ade', phoneRaw: '', email: 'bola@example.com'));
      final g = await GroupRepository(db).create('Choir');
      await GroupRepository(db).addContacts(g, [id]);
      await SettingsRepository(db).saveEmail(const EmailSettings(
          provider: EmailProvider.mailgun, domain: 'mg.example.com', apiKey: 'k', fromAddress: 'a@mg.example.com'));
    });
    appRouter.go('/');
    await settle(t);
    appRouter.go('/campaigns/new');
    await settle(t, until: find.text('Send by'));
    await t.enterText(find.widgetWithText(TextField, 'Campaign name'), 'Harvest');
    await t.tap(find.text('Text (SMS)'));
    await settle(t, until: find.text('Email').last);
    await t.tap(find.text('Email').last);
    await settle(t, until: find.text('Email subject'));
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'Hi {first_name}');
    await t.ensureVisible(find.textContaining('Choir'));
    await t.tap(find.textContaining('Choir'));
    await settle(t, until: find.text('Emails need a subject'));
    await t.enterText(find.widgetWithText(TextField, 'Email subject'), 'Welcome {first_name}');
    await settle(t);
    // The summary is at the bottom of the form.
    await t.drag(find.ancestor(of: find.text('Send by'), matching: find.byType(Scrollable)).first, const Offset(0, -1500));
    await settle(t, until: find.text('Welcome Bola'));
    expect(find.text('1 email'), findsOneWidget);
    expect(find.text('Email to bola@example.com'), findsOneWidget);
  });
}
