import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/app/theme.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/domain/models/campaign.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_composer.dart';
import 'package:sim_bulk_sms/features/dashboard/dashboard_screen.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

void main() {
  sqfliteFfiInit();
  late Database db;
  late int groupId;

  Future<void> openDb(WidgetTester t) async {
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true); // past first-launch setup
      final contacts = ContactRepository(db);
      groupId = await GroupRepository(db).create('Church');
      await GroupRepository(db).addContacts(groupId, [
        await contacts.add(const Contact(name: 'Ada Lovelace', phoneRaw: '+2341', phoneNormalized: '+2341')),
      ]);
    });
    addTearDown(() => t.runAsync(db.close));
  }

  Future<void> app(WidgetTester t, String location) async {
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    appRouter.go(location);
  }

  /// Real DB work runs outside the fake clock; [until] makes waits robust on slow machines.
  Future<void> settle(WidgetTester t, {Finder? until}) async {
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 300));
      if (i >= 4 && (until == null || until.evaluate().isNotEmpty)) return;
    }
  }

  Future<List<Campaign>> campaigns(WidgetTester t) async => (await t.runAsync(() => CampaignRepository(db).recent()))!;

  testWidgets('new campaign is autosaved as a draft and reopens with everything filled in', (t) async {
    await openDb(t);
    await app(t, '/');
    await settle(t);
    appRouter.push('/campaigns/new');
    await settle(t);

    await t.enterText(find.widgetWithText(TextField, 'Campaign name'), 'Harvest');
    await t.enterText(find.widgetWithText(TextField, 'Message'), 'Hi {first_name}, harvest is Sunday');
    await t.tap(find.text('Church (1)'));
    await settle(t, until: find.text('Draft saved'));

    var all = await campaigns(t);
    expect(all.single.status, CampaignStatus.draft);
    expect(all.single.name, 'Harvest');
    expect(all.single.messageTemplate, 'Hi {first_name}, harvest is Sunday');
    expect((await t.runAsync(() => CampaignRepository(db).audience(all.single.id)))!.groupIds, {groupId});

    await t.pageBack();
    await settle(t, until: find.text('Saved as a draft.'));
    expect(find.text('Saved as a draft.'), findsOneWidget);

    // Dashboard -> tap the draft -> back in the editor.
    await settle(t, until: find.text('Harvest'));
    await t.tap(find.text('Harvest'));
    await settle(t, until: find.text('Edit campaign'));
    expect(find.widgetWithText(TextField, 'Harvest'), findsOneWidget);
    expect(find.text('Hi {first_name}, harvest is Sunday'), findsOneWidget);
    final chip = t.widget<FilterChip>(find.widgetWithText(FilterChip, 'Church (1)'));
    expect(chip.selected, true);

    // Saving turns the same draft into a ready campaign (no duplicate).
    await settle(t, until: find.text('1 recipient'));
    await t.tap(find.text('Save and review'));
    await settle(t, until: find.text('Ready to send'));
    all = await campaigns(t);
    expect(all.single.status, CampaignStatus.ready);
  });

  testWidgets('opening and leaving an empty new campaign creates nothing', (t) async {
    await openDb(t);
    await app(t, '/');
    await settle(t);
    appRouter.push('/campaigns/new');
    await settle(t);
    await t.pageBack();
    await settle(t);
    expect(await campaigns(t), isEmpty);
    expect(find.text('Saved as a draft.'), findsNothing);
  });

  testWidgets('editing a ready campaign asks before discarding and never turns it into a draft', (t) async {
    await openDb(t);
    late int id;
    await t.runAsync(() async {
      final repo = CampaignRepository(db);
      final composer = CampaignComposer(contacts: ContactRepository(db), groups: GroupRepository(db), campaigns: repo);
      final plan = await composer.plan(template: 'Original', groupIds: {groupId}, contactIds: {});
      id = await composer.save(name: 'Ready one', template: 'Original', platform: 'android', plan: plan,
          audience: CampaignAudience(groupIds: {groupId}));
    });
    await app(t, '/');
    await settle(t);
    appRouter.push('/campaigns/$id/edit');
    await settle(t, until: find.text('Edit campaign'));

    await t.enterText(find.widgetWithText(TextField, 'Original'), 'Changed text');
    await settle(t);
    expect(find.text('Draft saved'), findsNothing);

    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await t.tap(find.text('Keep editing'));
    await t.pumpAndSettle();
    expect(find.text('Edit campaign'), findsOneWidget);

    await t.pageBack();
    await t.pumpAndSettle();
    await t.tap(find.text('Discard'));
    await settle(t);
    expect(find.text('Edit campaign'), findsNothing);
    final c = (await t.runAsync(() => CampaignRepository(db).get(id)))!;
    expect(c.status, CampaignStatus.ready);
    expect(c.messageTemplate, 'Original');
  });

  testWidgets('Save button stays visible above the keyboard', (t) async {
    await openDb(t);
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await app(t, '/campaigns/new');
    await settle(t);
    await t.tap(find.widgetWithText(TextField, 'Message'));
    t.view.viewInsets = const FakeViewPadding(bottom: 900); // ~300 logical px keyboard
    await t.pump();
    const screenHeight = 2340 / 3;
    final button = t.getRect(find.text('Save and review'));
    expect(button.bottom, lessThanOrEqualTo(screenHeight - 300));
    expect(find.text('Save and review').hitTestable(), findsOneWidget);
  });

  testWidgets('campaigns home: the last card scrolls clear of the navigation bar', (t) async {
    t.view.physicalSize = const Size(1080, 1500);
    t.view.devicePixelRatio = 3;
    t.view.viewPadding = const FakeViewPadding(bottom: 144); // 48 logical px gesture/nav bar
    t.view.padding = const FakeViewPadding(bottom: 144);
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        dashboardStatsProvider.overrideWith((ref) async => DashboardStats(contacts: 1, groups: 1, drafts: 0, recent: [
              for (var i = 0; i < 8; i++)
                Campaign(id: i, name: 'C$i', messageTemplate: 'x', status: CampaignStatus.completed,
                    platform: 'android', recipientCount: 1, createdAt: DateTime(2026)),
            ])),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const DashboardScreen()),
    ));
    await t.pumpAndSettle();
    await t.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await t.pumpAndSettle();
    final last = t.getRect(find.text('C7'));
    // Clear of the 48 px bar and of the floating "New campaign" button above it.
    expect(last.bottom, lessThanOrEqualTo(1500 / 3 - 48 - 56));
  });
}
