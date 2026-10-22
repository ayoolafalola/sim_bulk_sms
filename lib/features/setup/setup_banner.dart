import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'setup_status.dart';

/// Shown on every visit while a required permission/setting is off. Not dismissible.
class SetupBanner extends StatelessWidget {
  const SetupBanner({super.key, required this.missing});
  final List<SetupItem> missing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: const EdgeInsets.only(bottom: 12),
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
              child: Text('• ${setupInfoFor(i).title}: ${setupInfoFor(i).ifMissing}',
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
          const SizedBox(height: 4),
          FilledButton(onPressed: () => context.push('/settings/setup'), child: const Text('Fix now')),
        ]),
      ),
    );
  }
}
