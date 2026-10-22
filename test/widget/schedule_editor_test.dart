import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/data/repositories/schedule_repository.dart';
import 'package:sim_bulk_sms/domain/models/campaign.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/schedule.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_composer.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

void main() {
  sqfliteFfiInit();

  testWidgets('weekly schedule defaults to Sunday 08:00, shows the cost, and saves', (t) async {
    late Database db;
    late int campaignId;
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true); // past first-launch setup
      final contacts = ContactRepository(db), groups = GroupRepository(db), campaigns = CampaignRepository(db);
      final g = await groups.create('Church');
      await groups.addContacts(g, [
        await contacts.add(const Contact(name: 'Ada', phoneRaw: '+2341', phoneNormalized: '+2341')),
        await contacts.add(const Contact(name: 'Bola', phoneRaw: '+2342', phoneNormalized: '+2342')),
      ]);
      final composer = CampaignComposer(contacts: contacts, groups: groups, campaigns: campaigns);
      final plan = await composer.plan(template: 'Hi {first_name}', groupIds: {g}, contactIds: {});
      campaignId = await composer.save(name: 'Reminder', template: 'Hi {first_name}', platform: 'android',
          plan: plan, audience: CampaignAudience(groupIds: {g}));
      await campaigns.setStatus(campaignId, CampaignStatus.completed);
    });
    addTearDown(() => t.runAsync(db.close));

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    appRouter.go('/campaigns/$campaignId');
    await settle();
    expect(find.text('Send again'), findsOneWidget); // finished campaign
    await t.tap(find.text('Schedule…'));
    await settle();

    expect(find.text('Every Sun at 08:00'), findsOneWidget);
    expect(find.textContaining('Next run: Sun'), findsOneWidget);
    expect(find.textContaining('Each run sends about 2 messages'), findsOneWidget);
    expect(find.textContaining('will not ask again', skipOffstage: false), findsOneWidget);

    await t.tap(find.text('Fri'));
    await t.pump();
    expect(find.text('Every Fri, Sun at 08:00'), findsOneWidget);

    await t.tap(find.text('Save schedule'));
    await settle();
    await t.pump(const Duration(seconds: 1));

    final s = await t.runAsync(() => ScheduleRepository(db).forCampaign(campaignId));
    expect(s!.kind, ScheduleKind.weekly);
    expect(s.weekdays, CampaignSchedule.bit(DateTime.friday) | CampaignSchedule.bit(DateTime.sunday));
    expect(s.minuteOfDay, 480);
    expect(s.nextRunAt, isNotNull);
    await settle();
    expect(find.text('Every Fri, Sun at 08:00'), findsOneWidget); // schedule card on the campaign screen
    expect(find.text('Pause'), findsOneWidget);
  });

  testWidgets('one-time schedule needs a ready campaign', (t) async {
    late Database db;
    late int campaignId;
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true); // past first-launch setup
      final campaigns = CampaignRepository(db);
      campaignId = await campaigns.createDraft(name: 'Done', template: 'x', platform: 'android');
      await campaigns.setStatus(campaignId, CampaignStatus.completed);
    });
    addTearDown(() => t.runAsync(db.close));
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
      ],
      child: MaterialApp.router(routerConfig: appRouter),
    ));
    appRouter.go('/campaigns/$campaignId/schedule');
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.text('Once'));
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Only a campaign that is ready to send can be scheduled once'), findsOneWidget);
    final save = t.widget<FilledButton>(find.ancestor(of: find.text('Save schedule'), matching: find.byType(FilledButton)));
    expect(save.onPressed, isNull);
  });
}
