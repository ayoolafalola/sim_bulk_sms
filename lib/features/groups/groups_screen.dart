import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../common/page_layout.dart';

/// Asks for a group name. Returns the trimmed name, or null if cancelled.
Future<String?> askGroupName(BuildContext context, {String initial = '', required String title}) async {
  final ctrl = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Group name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
      ],
    ),
  );
  final t = name?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Groups')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final name = await askGroupName(context, title: 'New group');
          if (name == null) return;
          final id = await ref.read(groupRepositoryProvider).create(name);
          ref.read(dataVersionProvider.notifier).state++;
          if (context.mounted) context.go('/groups/$id');
        },
        icon: const Icon(Icons.group_add),
        label: const Text('New group'),
      ),
      body: groups.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Could not load groups.')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No groups yet. Groups let you pick many recipients at once.'))
            : ListView(padding: pagePadding(context, extra: fabClearance).copyWith(left: 0, right: 0, top: 0), children: [
                for (final g in list)
                  ListTile(
                    leading: const Icon(Icons.group_outlined),
                    title: Text(g.name),
                    subtitle: Text('${g.memberCount} ${g.memberCount == 1 ? 'member' : 'members'}'),
                    onTap: () => context.go('/groups/${g.id}'),
                  ),
              ]),
      ),
    );
  }
}
