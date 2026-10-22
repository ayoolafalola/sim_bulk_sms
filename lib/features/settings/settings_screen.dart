import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sendSettingsProvider).valueOrNull;
    final setup = ref.watch(setupStatusProvider).valueOrNull;
    String limit(int v, String per) => v > 0 ? '$v/$per' : 'no $per limit';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('Send settings'),
          subtitle: Text(s == null
              ? 'Delay, limits, default country'
              : 'Delay ${s.delaySeconds} s · ${limit(s.hourlyLimit, 'hour')} · ${limit(s.dailyLimit, 'day')} · ${s.defaultRegion}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/send'),
        ),
        ListTile(
          leading: Badge(isLabelVisible: setup != null && !setup.complete, child: const Icon(Icons.verified_user_outlined)),
          title: const Text('App setup'),
          subtitle: Text(setup == null
              ? 'Permissions and phone settings'
              : setup.complete
                  ? 'All required permissions are on'
                  : '${setup.missingRequired.length} required ${setup.missingRequired.length == 1 ? 'item' : 'items'} missing'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/settings/setup'),
        ),
      ]),
    );
  }
}
