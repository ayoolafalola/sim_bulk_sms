import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/domain/models/campaign.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_detail_screen.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_editor_screen.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);
const androidBlocked = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.playPolicyUnresolved,
    messageForUser: 'Direct sending is disabled in this build.');
const ios = SmsCapabilities(platform: SmsPlatform.ios, canSendDirectly: false,
    usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.none);

Campaign campaign(CampaignStatus s) => Campaign(id: 1, name: 'Launch', messageTemplate: 'Hi {first_name}',
    status: s, platform: 'android', recipientCount: 2, createdAt: DateTime(2026));
CampaignRecipient rec(int id, RecipientStatus s) => CampaignRecipient(id: id, campaignId: 1, name: 'R$id',
    phone: '+100$id', renderedMessage: 'Hi R$id', status: s, attemptCount: s == RecipientStatus.pending ? 0 : 1);

Widget host(CampaignStatus status, List<CampaignRecipient> recipients, SmsCapabilities caps) => ProviderScope(
      overrides: [
        campaignProvider.overrideWith((ref, id) async => campaign(status)),
        campaignRecipientsProvider.overrideWith((ref, id) async => recipients),
        capabilitiesProvider.overrideWith((ref) async => caps),
      ],
      child: const MaterialApp(home: CampaignDetailScreen(campaignId: 1)),
    );

void main() {
  final pending = [rec(1, RecipientStatus.pending), rec(2, RecipientStatus.pending)];

  testWidgets('ready campaign on a capable Android device offers Send', (t) async {
    await t.pumpWidget(host(CampaignStatus.ready, pending, androidOk));
    await t.pumpAndSettle();
    expect(find.text('Ready to send'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Waiting: 2'), findsOneWidget);
  });

  testWidgets('blocked Android build explains why and offers no Send', (t) async {
    await t.pumpWidget(host(CampaignStatus.ready, pending, androidBlocked));
    await t.pumpAndSettle();
    expect(find.text('Direct sending is disabled in this build.'), findsOneWidget);
    final btn = t.widget<FilledButton>(find.ancestor(of: find.text('Send'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(btn.onPressed, isNull);
  });

  testWidgets('iOS hands off one message at a time', (t) async {
    await t.pumpWidget(host(CampaignStatus.ready, pending, ios));
    await t.pumpAndSettle();
    expect(find.text('Open next message (1 of 2)'), findsOneWidget);
  });

  testWidgets('running campaign offers Pause and Cancel, not Send or Delete', (t) async {
    await t.pumpWidget(host(CampaignStatus.running, [rec(1, RecipientStatus.submitted), rec(2, RecipientStatus.pending)], androidOk));
    await t.pumpAndSettle();
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Cancel campaign'), findsOneWidget);
    expect(find.text('Send'), findsNothing);
    expect(find.byTooltip('Delete'), findsNothing);
  });

  testWidgets('unknown recipient warns before sending again', (t) async {
    await t.pumpWidget(host(CampaignStatus.partiallyCompleted,
        [rec(1, RecipientStatus.sent), rec(2, RecipientStatus.unknown)], androidOk));
    await t.pumpAndSettle();
    expect(find.text('Sent: 1'), findsOneWidget);
    expect(find.text('Unknown: 1'), findsOneWidget);
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    expect(find.text('Send again (may duplicate)'), findsOneWidget);
    expect(find.text('I checked: it was sent'), findsOneWidget);
  });

  testWidgets('plan summary names unresolved variables', (t) async {
    final plan = buildSnapshotPlan(template: 'Hi {event_name}',
        contacts: const [Contact(name: 'Ada', phoneRaw: '+2341', phoneNormalized: '+2341')], suppressedE164: {});
    await t.pumpWidget(MaterialApp(home: Scaffold(body: PlanSummary(plan))));
    expect(find.textContaining('{event_name}'), findsOneWidget);
    expect(find.text('0 recipients'), findsOneWidget);
  });
}
