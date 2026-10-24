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
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/platform/contacts/phone_contacts_service.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: true, blocker: DirectSendBlocker.none);

class _NoPhoneContacts extends FakePhoneContactsBase {
  @override Future<bool> hasPermission() async => false;
  @override Future<bool> requestPermission() async => false;
  @override Future<List<PhoneContact>> load() async => const [];
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late FakeMessagesService inbox;

  Future<void> start(WidgetTester t, {List<SimSubscription> sims = const [], Future<void> Function()? seed}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true);
      await seed?.call();
    });
    addTearDown(() => t.runAsync(db.close));
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        messagesServiceProvider.overrideWithValue(inbox),
        backgroundSendServiceProvider.overrideWithValue(FakeBackground(everythingGranted)),
        smsServiceProvider.overrideWithValue(FakeSmsService(androidOk, sims: sims)),
        phoneContactsServiceProvider.overrideWithValue(_NoPhoneContacts()),
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

  setUp(() => inbox = FakeMessagesService());

  testWidgets('campaign texts are labelled in the conversation and link to the campaign', (t) async {
    late int campaignId;
    await start(t, seed: () async {
      final repo = CampaignRepository(db);
      campaignId = await repo.createDraft(name: 'Harvest Sunday', template: 'Hi', platform: 'android');
      await repo.saveSnapshot(campaignId, const [SnapshotRecipient(name: 'Ada', phoneE164: '+2341', renderedMessage: 'Hi Ada')]);
      final rid = (await repo.recipients(campaignId)).single.id;
      await db.insert('stored_messages', {'sms_id': 777, 'campaign_recipient_id': rid, 'created_at': '2026-10-22T00:00:00Z'});
    });
    inbox.addSent(1, '+2341', 'Hi Ada', 777);
    inbox.receive(1, '+2341', 'Thanks!');
    await settle(t, until: find.text('+2341'));
    await t.tap(find.text('+2341'));
    await settle(t, until: find.text('Campaign · Harvest Sunday'));
    await t.tap(find.text('Campaign · Harvest Sunday'));
    await settle(t, until: find.text('Ready to send'));
    expect(find.text('Harvest Sunday'), findsWidgets);
    expect(campaignId, isPositive);
  });

  testWidgets('long-press: copy or delete a message, with Undo', (t) async {
    await start(t);
    inbox.receive(1, '+2341', 'Keep me');
    inbox.receive(1, '+2341', 'Delete me');
    await settle(t, until: find.text('+2341'));
    await t.tap(find.text('+2341'));
    await settle(t, until: find.text('Delete me'));

    await t.longPress(find.text('Delete me'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(find.text('Delete me'), findsNothing);
    await t.tap(find.text('Undo'));
    await t.pumpAndSettle();
    expect(find.text('Delete me'), findsOneWidget);

    await t.longPress(find.text('Delete me'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pump();
    ScaffoldMessenger.of(t.element(find.text('Message deleted'))).hideCurrentSnackBar();
    await settle(t);
    expect(inbox.threads[1]!.map((m) => m.body), ['Keep me']);
  });

  testWidgets('inbox: mark all as read; delete a conversation after confirming', (t) async {
    await start(t);
    inbox.receive(1, '+2341', 'One');
    inbox.receive(2, '+2342', 'Two');
    await settle(t, until: find.byTooltip('Mark all as read'));
    await t.tap(find.byTooltip('Mark all as read'));
    await settle(t);
    expect(find.byTooltip('Mark all as read'), findsNothing);

    await t.longPress(find.text('+2342'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete conversation'));
    await t.pumpAndSettle();
    expect(find.text('Delete conversation with +2342?'), findsOneWidget);
    await t.tap(find.text('Delete'));
    await settle(t);
    expect(find.text('+2342'), findsNothing);
    expect(inbox.threads.containsKey(2), false);
  });

  testWidgets('dual SIM: replies use the SIM they texted you on, and you can switch it', (t) async {
    await start(t, sims: const [
      SimSubscription(id: 11, slotIndex: 0, carrier: 'MTN'),
      SimSubscription(id: 22, slotIndex: 1, carrier: 'Airtel'),
    ]);
    inbox.receive(1, '+2341', 'Hi', subId: 22);
    await settle(t, until: find.text('+2341'));
    await t.tap(find.text('+2341'));
    await settle(t, until: find.text('SIM 2 · Airtel'));
    await t.tap(find.text('SIM 2 · Airtel'));
    await t.pumpAndSettle();
    await t.tap(find.text('SIM 1 · MTN'));
    await settle(t, until: find.text('SIM 1 · MTN'));
    await t.enterText(find.widgetWithText(TextField, 'Text message'), 'Hello');
    await t.tap(find.byTooltip('Send'));
    await settle(t);
    expect(inbox.sentSubIds.last, 11);
    expect(await t.runAsync(() => SettingsRepository(db).simForThread(1)), 11);
  });

  testWidgets('new message to several people: each gets their own text', (t) async {
    await start(t, seed: () async {
      await ContactRepository(db).add(const Contact(name: 'Ada Okafor', phoneRaw: '0803', phoneNormalized: '+2348031234567'));
    });
    await settle(t, until: find.text('New message'));
    await t.tap(find.text('New message'));
    await settle(t, until: find.text('Name or number'));
    await t.enterText(find.widgetWithText(TextField, 'Name or number'), 'Ada');
    await settle(t, until: find.text('Ada Okafor'));
    await t.tap(find.text('Ada Okafor'));
    await t.pump();
    await t.enterText(find.widgetWithText(TextField, 'Name or number'), '08059990000');
    await settle(t, until: find.text('+2348059990000'));
    await t.tap(find.text('+2348059990000'));
    await t.pump();
    await t.enterText(find.widgetWithText(TextField, 'Text message'), 'Rehearsal at 5');
    await t.pump();
    await t.tap(find.byTooltip('Send'));
    await settle(t, until: find.text('Sent to 2 people.'));
    expect(inbox.sent.toSet(), {('+2348031234567', 'Rehearsal at 5'), ('+2348059990000', 'Rehearsal at 5')});
  });

  testWidgets('from a conversation: save the number and add it to a group', (t) async {
    late int gid;
    await start(t, seed: () async => gid = await GroupRepository(db).create('Choir'));
    inbox.receive(1, '+2348031234567', 'Hi, add me please');
    await settle(t, until: find.text('+2348031234567'));
    await t.tap(find.text('+2348031234567'));
    await settle(t, until: find.byTooltip('More'));
    await t.tap(find.byTooltip('More'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add to group…'));
    await settle(t, until: find.text('Choir'));
    await t.tap(find.text('Choir'));
    await settle(t, until: find.text('Save contact'));
    await t.enterText(find.byType(TextField).last, 'Bola');
    await t.tap(find.text('Save'));
    await settle(t, until: find.text('Added to Choir'));
    final members = (await t.runAsync(() => GroupRepository(db).members(gid)))!;
    expect(members.single.name, 'Bola');
    await settle(t, until: find.textContaining('Choir'));
    expect(find.textContaining('Choir'), findsWidgets); // header shows the group
  });
}
