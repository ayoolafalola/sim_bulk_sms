import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/schedule_calculator.dart';
import '../campaigns/campaign_labels.dart';
import '../setup/setup_status.dart';
import '../common/page_layout.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(dashboardStatsProvider);
    final caps = ref.watch(capabilitiesProvider);
    final setup = ref.watch(setupStatusProvider).valueOrNull;
    final setupMissing = setup != null && !setup.complete;
    // Fresh install: run the first-launch setup.
    ref.listen(onboardingDoneProvider, (_, next) {
      if (next.valueOrNull == false) context.go('/welcome');
    });
    return Scaffold(
      appBar: AppBar(title: const Text('SIM Bulk SMS'), actions: [
        IconButton(
            tooltip: 'Settings',
            icon: Badge(isLabelVisible: setupMissing, child: const Icon(Icons.settings_outlined)),
            onPressed: () => context.go('/settings')),
      ]),
      // Generous bottom room so the last buttons are never under the navigation bar.
      body: ListView(padding: pagePadding(context, extra: 96), children: [
        if (setupMissing) _SetupBanner(missing: setup.missingRequired),
        caps.when(
          data: (c) => _CapabilityCard(c),
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => const _Banner(
              icon: Icons.error_outline,
              text: 'Messaging capabilities could not be determined on this device. Sending is unavailable.'),
        ),
        const SizedBox(height: 16),
        stats.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => const _Banner(icon: Icons.error_outline, text: 'Could not load your data.'),
          data: (s) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: _Stat('Contacts', s.contacts)),
              Expanded(child: _Stat('Groups', s.groups)),
              Expanded(child: _Stat('Drafts', s.drafts)),
            ]),
            const SizedBox(height: 16),
            Text('Recent campaigns', style: Theme.of(context).textTheme.titleMedium),
            if (s.recent.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('No campaigns yet.'))
            else
              for (final c in s.recent)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(c.name),
                  subtitle: Text('${c.recipientCount} recipients'),
                  trailing: Chip(label: Text(campaignStatusLabel(c.status))),
                  // A draft opens straight back into the editor.
                  onTap: () => context.go(c.status == CampaignStatus.draft ? '/campaigns/${c.id}/edit' : '/campaigns/${c.id}'),
                ),
          ]),
        ),
        const _ScheduledList(),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: () => context.go('/campaigns/new'),
            icon: const Icon(Icons.campaign_outlined),
            label: const Text('New campaign')),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
                onPressed: () => context.go('/contacts'),
                icon: const Icon(Icons.contacts_outlined),
                label: const Text('Contacts')),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
                onPressed: () => context.go('/groups'),
                icon: const Icon(Icons.group_outlined),
                label: const Text('Groups')),
          ),
        ]),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Text('$value', style: Theme.of(context).textTheme.headlineMedium),
            Text(label),
          ]),
        ),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [Icon(icon), const SizedBox(width: 12), Expanded(child: Text(text))]),
        ),
      );
}

class _CapabilityCard extends ConsumerWidget {
  const _CapabilityCard(this.c);
  final SmsCapabilities c;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String text;
    if (c.canSendDirectly) {
      text = 'This device can send SMS directly through your SIM. Carrier charges apply.';
    } else {
      text = c.messageForUser ?? 'Direct sending is not available on this device.';
    }
    final banner = _Banner(icon: c.canSendDirectly ? Icons.sim_card_outlined : Icons.info_outline, text: text);
    if (c.blocker != DirectSendBlocker.permissionDenied) return banner;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      banner,
      const SizedBox(height: 8),
      FilledButton.tonalIcon(
        onPressed: () async {
          final ok = await ref.read(smsServiceProvider).requestRequiredPermissions();
          ref.invalidate(capabilitiesProvider);
          if (!ok && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('SMS permission was not granted. You can allow it in the system app settings.')));
          }
        },
        icon: const Icon(Icons.lock_open),
        label: const Text('Allow SMS permission'),
      ),
    ]);
  }
}

/// Upcoming and paused schedules. Hidden when there are none.
class _ScheduledList extends ConsumerWidget {
  const _ScheduledList();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(schedulesProvider).valueOrNull ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text('Scheduled', style: Theme.of(context).textTheme.titleMedium),
      for (final i in items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(i.schedule.enabled ? Icons.event_repeat : Icons.pause_circle_outline),
          title: Text(i.campaignName),
          subtitle: Text([
            describeSchedule(specOf(i.schedule)),
            if (!i.schedule.enabled) i.schedule.nextRunAt == null ? 'Finished' : 'Paused'
            else if (i.schedule.nextRunAt != null) 'Next: ${formatDateTime(i.schedule.nextRunAt!)}',
            if (i.schedule.lastOutcome != null) 'Last: ${scheduleOutcomeLabel(i.schedule.lastOutcome!)}',
          ].join('\n')),
          isThreeLine: i.schedule.lastOutcome != null,
          onTap: () => context.go('/campaigns/${i.schedule.campaignId}'),
        ),
    ]);
  }
}

/// Shown on every visit while a required permission/setting is off. Not dismissible.
class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.missing});
  final List<SetupItem> missing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.warning_amber, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${missing.length} required ${missing.length == 1 ? 'permission is' : 'permissions are'} off',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          for (final i in missing)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• ${setupInfo[i]!.title}: ${setupInfo[i]!.ifMissing}',
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          const SizedBox(height: 4),
          FilledButton(onPressed: () => context.push('/settings/setup'), child: const Text('Fix now')),
        ]),
      ),
    );
  }
}
