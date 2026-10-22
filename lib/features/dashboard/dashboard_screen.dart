import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/schedule_calculator.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../campaigns/campaign_labels.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../setup/setup_banner.dart';

/// The Campaigns tab (home): this week at a glance, what's scheduled, drafts
/// and recent sends with progress. One button to start a new campaign.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(dashboardStatsProvider);
    final caps = ref.watch(capabilitiesProvider).valueOrNull;
    final setup = ref.watch(setupStatusProvider).valueOrNull;
    final schedules = ref.watch(schedulesProvider).valueOrNull ?? const <ScheduleListItem>[];
    final settings = ref.watch(sendSettingsProvider).valueOrNull;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        // Tabs stay alive side by side under the shell: each FAB needs its own hero tag.
        heroTag: 'fab-campaigns',
        onPressed: () => context.push('/campaigns/new'),
        icon: const Icon(Icons.add),
        label: const Text('New campaign'),
      ),
      body: SafeArea(
        bottom: false,
        child: stats.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => const Center(child: Text('Could not load your campaigns.')),
          data: (s) {
            final hidden = ref.watch(pendingCampaignDeletesProvider);
            final shown = s.recent.where((c) => !hidden.contains(c.id)).toList();
            final drafts = shown.where((c) => c.status == CampaignStatus.draft).toList();
            final sent = shown.where((c) => c.status != CampaignStatus.draft).toList();
            final nothingYet = shown.isEmpty && schedules.isEmpty;
            return ListView(padding: pagePadding(context, extra: fabClearance).copyWith(top: 0), children: [
              const TabTitle('Campaigns'),
              if (setup != null && !setup.complete) SetupBanner(missing: setup.missingRequired),
              if (caps != null && !caps.canSendDirectly) _CapabilityNote(caps),
              if (nothingYet)
                _Welcome(contacts: s.contacts)
              else ...[
                _WeekCard(stats: s, dailyLimit: settings?.dailyLimit ?? 0),
                if (schedules.isNotEmpty) ...[
                  const SectionLabel('Scheduled'),
                  for (final i in schedules) _ScheduleCard(i),
                ],
                if (drafts.isNotEmpty) ...[
                  const SectionLabel('Drafts'),
                  for (final c in drafts) _DraftCard(c),
                ],
                if (sent.isNotEmpty) ...[
                  const SectionLabel('Recent'),
                  for (final c in sent) _CampaignCard(c, s.progress[c.id] ?? const {}),
                ],
              ],
            ]);
          },
        ),
      ),
    );
  }
}

class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.stats, required this.dailyLimit});
  final DashboardStats stats;
  final int dailyLimit;

  @override
  Widget build(BuildContext context) {
    final onGreen = Theme.of(context).colorScheme.onPrimary;
    Widget figure(String value, String label) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: onGreen)),
            Text(label, style: TextStyle(fontSize: 13, color: onGreen.withValues(alpha: 0.85))),
          ]),
        );
    final delivered = stats.sentThisWeek == 0 || stats.deliveredThisWeek == 0
        ? '—'
        : '${(100 * stats.deliveredThisWeek / stats.sentThisWeek).round()}%';
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(22)),
      child: Row(children: [
        figure('${stats.sentThisWeek}', 'sent this week'),
        figure(delivered, 'delivered'),
        figure('${stats.contacts}', 'contacts'),
      ]),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.contacts});
  final int contacts;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: EmptyState(
          icon: Icons.campaign_outlined,
          title: 'No campaigns yet',
          text: contacts == 0
              ? 'Start by adding the people you want to message. Then write one message and send it to everyone.'
              : 'You have $contacts contacts. Write a message once and send it to a group.',
          action: contacts == 0
              ? FilledButton.icon(
                  onPressed: () => context.go('/contacts'),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Add contacts'))
              : FilledButton.icon(
                  onPressed: () => context.push('/campaigns/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New campaign')),
        ),
      );
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard(this.i);
  final ScheduleListItem i;

  @override
  Widget build(BuildContext context) {
    final s = i.schedule;
    final c = AppColors.of(context);
    final next = s.enabled ? s.nextRunAt : null;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push('/campaigns/${s.campaignId}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 56,
              height: 58,
              decoration: BoxDecoration(color: s.enabled ? c.warnBg : c.neutralBg, borderRadius: BorderRadius.circular(14)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(next == null ? (s.enabled ? 'DONE' : 'PAUSED') : formatWhen(next).split(' ').first.toUpperCase(),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: c.warnFg)),
                if (next != null)
                  Text('${next.hour.toString().padLeft(2, '0')}:${next.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.campaignName, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(describeSchedule(specOf(s)), style: TextStyle(color: c.muted, fontSize: 13)),
                if (s.lastOutcome != null) ...[
                  const SizedBox(height: 6),
                  StatusTag('Last: ${scheduleOutcomeLabel(s.lastOutcome!)}',
                      tone: s.lastOutcome!.name == 'started' ? Tone.success : Tone.warn),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard(this.c);
  final Campaign c;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          // A draft opens straight back into the editor.
          onTap: () => context.push('/campaigns/${c.id}/edit'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(c.name, style: Theme.of(context).textTheme.titleMedium)),
                const StatusTag('Draft'),
              ]),
              if (c.messageTemplate.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(c.messageTemplate, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.of(context).muted)),
              ],
            ]),
          ),
        ),
      );
}


class _CampaignCard extends StatelessWidget {
  const _CampaignCard(this.c, this.counts);
  final Campaign c;
  final Map<RecipientStatus, int> counts;

  @override
  Widget build(BuildContext context) {
    final total = c.recipientCount;
    final done = total - (counts[RecipientStatus.pending] ?? 0);
    final ok = (counts[RecipientStatus.sent] ?? 0) + (counts[RecipientStatus.delivered] ?? 0);
    final failed = counts[RecipientStatus.failed] ?? 0;
    final delivered = counts[RecipientStatus.delivered] ?? 0;
    final detail = [
      '$total ${total == 1 ? 'person' : 'people'}',
      if (ok > 0) '$ok sent',
      if (delivered > 0) '$delivered delivered',
      if (failed > 0) '$failed failed',
      if (pausedReasonText(c) case final why?) why,
    ].join(' · ');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push('/campaigns/${c.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(c.name, style: Theme.of(context).textTheme.titleMedium)),
              StatusTag(campaignStatusLabel(c.status), tone: campaignTone(c.status)),
            ]),
            if (total > 0) ...[
              const SizedBox(height: 12),
              ProgressLine(value: done / total, tone: campaignTone(c.status) == Tone.danger ? Tone.danger : Tone.success),
            ],
            const SizedBox(height: 8),
            Text(detail, style: TextStyle(fontSize: 13, color: AppColors.of(context).muted)),
          ]),
        ),
      ),
    );
  }
}

/// Only when the phone can't send by itself (e.g. Messages-app mode); kept short.
class _CapabilityNote extends StatelessWidget {
  const _CapabilityNote(this.c);
  final SmsCapabilities c;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: colors.infoBg, borderRadius: BorderRadius.circular(16)),
      child: Row(children: [
        Icon(Icons.info_outline, color: colors.infoFg),
        const SizedBox(width: 10),
        Expanded(
          child: Text(c.messageForUser ?? 'Direct sending is not available on this device.',
              style: TextStyle(color: colors.infoFg)),
        ),
      ]),
    );
  }
}
