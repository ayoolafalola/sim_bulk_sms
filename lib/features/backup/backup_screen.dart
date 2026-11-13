import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../account/account_controller.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import 'backup_controller.dart';
import 'backup_sync.dart';

/// Settings › Backup and sync.
class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  static const _steps = [
    'Getting changes from your other devices',
    'Backing up contacts',
    'Backing up groups',
    'Backing up campaigns',
    'Backing up texts',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(accountProvider).valueOrNull != null;
    final on = ref.watch(backupEnabledProvider).valueOrNull ?? false;
    final backup = ref.watch(backupControllerProvider);
    final c = AppColors.of(context);
    if (!signedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('Backup and sync')),
        body: EmptyState(
          icon: Icons.cloud_outlined,
          title: 'Back up with Contacts++',
          text: 'Sign in with Contacts++ to keep your contacts, groups, campaigns and texts safe, and to use them on the web.',
          action: FilledButton.icon(
            onPressed: () => context.push('/settings/account'),
            icon: const Icon(Icons.login),
            label: const Text('Sign in'),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Backup and sync')),
      body: ListView(padding: pagePadding(context, extra: 24), children: [
        Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Back up to Contacts++'),
            subtitle: const Text('Contacts and groups stay in step with the web and your other phones. '
                'Campaigns and the last 90 days of texts are backed up.'),
            value: on,
            onChanged: (v) => ref.read(backupControllerProvider.notifier).setEnabled(v),
          ),
        ),
        const SizedBox(height: 12),
        if (backup.running)
          _StepsCard(progress: backup.progress, steps: _steps)
        else ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(backup.error != null ? Icons.error_outline : Icons.history, color: backup.error != null ? c.dangerFg : c.muted),
            title: Text(backup.error ??
                (backup.lastAt == null ? 'Not backed up yet' : 'Last backup ${_ago(backup.lastAt!)}')),
            subtitle: backup.report == null
                ? null
                : Text('${backup.report!.uploaded} sent · ${backup.report!.downloaded} received from other devices'),
          ),
          FilledButton.icon(
            onPressed: on ? () => ref.read(backupControllerProvider.notifier).runNow() : null,
            icon: const Icon(Icons.backup_outlined),
            label: Text(backup.error != null ? 'Try again' : 'Back up now'),
          ),
        ],
        const SectionLabel('Your backup'),
        Text(
          'Stored by Contacts++, encrypted on its servers, and visible only to you, here and at messages.comeriver.com. '
          'Deleting it leaves everything on this phone.',
          style: TextStyle(color: c.muted, height: 1.4),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: backup.running ? null : () => _confirmDelete(context, ref),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete backup'),
          ),
        ),
      ]),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your backup?'),
        content: const Text('Your Messages++ backup is removed from Contacts++ and the web app. '
            'Nothing on this phone changes. This can’t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(backupControllerProvider.notifier).deleteBackup();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn’t delete the backup. Try again.')));
      }
    }
  }

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }
}

/// "2/5 · Backing up contacts · 12/40", with the steps done and still to come.
class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.progress, required this.steps});
  final SyncProgress? progress;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final p = progress;
    final current = p?.step ?? 1;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$current/${steps.length} · ${p?.label ?? steps.first}${p != null && p.of > 0 ? ' · ${p.done}/${p.of}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          ProgressLine(value: ((current - 1) + (p != null && p.of > 0 ? p.done / p.of : 0)) / steps.length),
          const SizedBox(height: 10),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Icon(
                  i + 1 < current ? Icons.check_circle : (i + 1 == current ? Icons.timelapse : Icons.radio_button_unchecked),
                  size: 18,
                  color: i + 1 < current ? c.successFg : c.muted,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(steps[i], style: TextStyle(color: i + 1 <= current ? null : c.muted))),
              ]),
            ),
        ]),
      ),
    );
  }
}
