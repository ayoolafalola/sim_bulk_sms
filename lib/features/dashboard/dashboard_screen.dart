import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../platform/sms/sms_capability_service.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(dashboardStatsProvider);
    final caps = ref.watch(capabilitiesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('SIM Bulk SMS')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
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
                  trailing: Chip(label: Text(c.status.name)),
                ),
          ]),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: () => context.go('/contacts'),
            icon: const Icon(Icons.contacts_outlined),
            label: const Text('Manage contacts')),
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

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard(this.c);
  final SmsCapabilities c;
  @override
  Widget build(BuildContext context) {
    final String text;
    if (c.canSendDirectly) {
      text = 'This device can send SMS directly through your SIM. Carrier charges apply.';
    } else {
      text = c.messageForUser ?? 'Direct sending is not available on this device.';
    }
    return _Banner(icon: c.canSendDirectly ? Icons.sim_card_outlined : Icons.info_outline, text: text);
  }
}
