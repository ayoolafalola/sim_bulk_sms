import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/sending_providers.dart';
import 'package:sim_bulk_sms/app/theme.dart';
import 'package:sim_bulk_sms/domain/models/campaign.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/features/dashboard/dashboard_screen.dart';
import 'package:sim_bulk_sms/features/setup/setup_status.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

Campaign campaign(int id, String name, CampaignStatus s, {int n = 10, String template = 'Hi'}) => Campaign(
    id: id, name: name, messageTemplate: template, status: s, platform: 'android', recipientCount: n,
    createdAt: DateTime(2026, 10, 20));

Widget host(DashboardStats stats, {SmsCapabilities caps = androidOk, SetupStatus? setup}) => ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => caps),
        dashboardStatsProvider.overrideWith((ref) async => stats),
        setupStatusProvider.overrideWith((ref) async => setup),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const DashboardScreen()),
    );

void main() {
  testWidgets('no campaigns yet: one clear next step', (t) async {
    await t.pumpWidget(host(const DashboardStats(contacts: 0, groups: 0, drafts: 0, recent: [])));
    await t.pumpAndSettle();
    expect(find.text('No campaigns yet'), findsOneWidget);
    expect(find.text('Add contacts'), findsOneWidget);
    expect(find.text('New campaign'), findsWidgets); // the floating button
  });

  testWidgets('with contacts but no campaigns: offers to write the first one', (t) async {
    await t.pumpWidget(host(const DashboardStats(contacts: 12, groups: 1, drafts: 0, recent: [])));
    await t.pumpAndSettle();
    expect(find.textContaining('You have 12 contacts'), findsOneWidget);
  });

  testWidgets('week summary, drafts and recent campaigns with progress', (t) async {
    await t.pumpWidget(host(DashboardStats(
      contacts: 40, groups: 2, drafts: 1, sentThisWeek: 200, deliveredThisWeek: 150,
      recent: [
        campaign(1, 'Youth camp', CampaignStatus.draft, template: 'Registration is open'),
        campaign(2, 'Harvest Sunday', CampaignStatus.completed, n: 4),
      ],
      progress: const {2: {RecipientStatus.delivered: 3, RecipientStatus.failed: 1}},
    )));
    await t.pumpAndSettle();
    expect(find.text('200'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('DRAFTS'), findsOneWidget);
    expect(find.text('Youth camp'), findsOneWidget);
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('4 people · 3 sent · 3 delivered · 1 failed'), findsOneWidget);
  });

  testWidgets('Messages-app mode is explained', (t) async {
    await t.pumpWidget(host(const DashboardStats(contacts: 1, groups: 0, drafts: 0, recent: []), caps: androidFallback));
    await t.pumpAndSettle();
    expect(find.textContaining('Messages open in your Messages app'), findsOneWidget);
  });

  testWidgets('direct sending needs no note', (t) async {
    await t.pumpWidget(host(const DashboardStats(contacts: 1, groups: 0, drafts: 0, recent: [])));
    await t.pumpAndSettle();
    expect(find.textContaining('Messages app'), findsNothing);
  });

  testWidgets('missing permissions: non-dismissible banner with Fix now', (t) async {
    await t.pumpWidget(host(const DashboardStats(contacts: 1, groups: 0, drafts: 0, recent: []),
        setup: SetupStatus.fromAndroid(nothingGranted, store: false)));
    await t.pumpAndSettle();
    expect(find.text('4 required permissions are off'), findsOneWidget);
    expect(find.text('Fix now'), findsOneWidget);
  });
}
