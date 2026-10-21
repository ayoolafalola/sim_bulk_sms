import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/features/dashboard/dashboard_screen.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';

Widget host(SmsCapabilities caps, DashboardStats stats) => ProviderScope(
      overrides: [
        capabilitiesProvider.overrideWith((ref) async => caps),
        dashboardStatsProvider.overrideWith((ref) async => stats),
      ],
      child: const MaterialApp(home: DashboardScreen()),
    );

void main() {
  const empty = DashboardStats(contacts: 3, groups: 2, drafts: 1, recent: []);

  testWidgets('shows persisted counts and empty campaign state', (t) async {
    await t.pumpWidget(host(
        const SmsCapabilities(platform: SmsPlatform.ios, canSendDirectly: false,
            usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.none,
            messageForUser: 'iOS requires you to tap Send in the Messages composer for each message.'),
        empty));
    await t.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('No campaigns yet.'), findsOneWidget);
  });

  testWidgets('iOS limitation is shown honestly', (t) async {
    await t.pumpWidget(host(
        const SmsCapabilities(platform: SmsPlatform.ios, canSendDirectly: false,
            usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.none,
            messageForUser: 'iOS requires you to tap Send in the Messages composer for each message.'),
        empty));
    await t.pumpAndSettle();
    expect(find.textContaining('tap Send'), findsOneWidget);
    expect(find.textContaining('directly through your SIM'), findsNothing);
  });

  testWidgets('Android with unresolved Play policy does not claim direct sending', (t) async {
    await t.pumpWidget(host(
        const SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false,
            usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.playPolicyUnresolved,
            messageForUser: 'Direct sending is disabled in this build until Google Play SMS permission eligibility is resolved.'),
        empty));
    await t.pumpAndSettle();
    expect(find.textContaining('Direct sending is disabled'), findsOneWidget);
  });

  testWidgets('direct-send capability is announced when real', (t) async {
    await t.pumpWidget(host(
        const SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
            usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none),
        empty));
    await t.pumpAndSettle();
    expect(find.textContaining('directly through your SIM'), findsOneWidget);
  });
}
