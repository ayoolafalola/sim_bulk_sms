import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../domain/models/contact.dart';
import '../contacts/contact_sync_runner.dart';
import 'groups_screen.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';

class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({super.key, required this.groupId});
  final int groupId;

  void _refresh(WidgetRef ref) => ref.read(dataVersionProvider.notifier).state++;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).valueOrNull;
    final group = groups?.where((g) => g.id == groupId).firstOrNull;
    final members = ref.watch(groupMembersProvider(groupId));
    final repo = ref.read(groupRepositoryProvider);
    // With phone contacts synced, everyone is already here: "Add members" covers it.
    final syncOn = ref.watch(contactsSyncModeProvider).valueOrNull == true;
    return Scaffold(
      appBar: AppBar(title: Text(group?.name ?? 'Group'), actions: [
        if (!syncOn)
        IconButton(
          tooltip: 'Add from phone',
          icon: const Icon(Icons.contact_phone_outlined),
          onPressed: () => context.push('/contacts/import?group=$groupId'),
        ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'rename') {
              final name = await askGroupName(context, initial: group?.name ?? '', title: 'Rename group');
              if (name == null) return;
              await repo.rename(groupId, name);
              _refresh(ref);
            } else if (v == 'delete') {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete group?'),
                  content: const Text('The contacts stay in your contact list. Existing campaigns are not affected.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok != true) return;
              await repo.delete(groupId);
              _refresh(ref);
              if (context.mounted) context.go('/groups');
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'delete', child: Text('Delete group')),
          ],
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final current = members.valueOrNull?.map((c) => c.id!).toSet() ?? {};
          final all = await ref.read(allContactsProvider.future);
          if (!context.mounted) return;
          final picked = await pickContacts(context, all, exclude: current, title: 'Add to group');
          if (picked == null || picked.isEmpty) return;
          await repo.addContacts(groupId, picked);
          _refresh(ref);
        },
        icon: const Icon(Icons.person_add),
        label: const Text('Add members'),
      ),
      body: members.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Could not load members.')),
        data: (list) => list.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('This group has no members yet.'),
                  if (!syncOn)
                  TextButton.icon(
                      onPressed: () => context.push('/contacts/import?group=$groupId'),
                      icon: const Icon(Icons.contact_phone_outlined),
                      label: const Text('Add from phone contacts')),
                ]),
              )
            : ListView(padding: pagePadding(context, extra: fabClearance).copyWith(left: 0, right: 0, top: 0), children: [
                for (final c in list)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    leading: InitialsAvatar(c.name),
                    title: Text(c.name),
                    subtitle: Text(c.phoneNormalized ?? c.phoneRaw),
                    trailing: IconButton(
                      tooltip: 'Remove from group',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () async {
                        // Removing is instant and can be undone (re-adds the same contact).
                        await repo.removeContact(groupId, c.id!);
                        _refresh(ref);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Removed ${c.name} from the group'),
                          action: SnackBarAction(label: 'Undo', onPressed: () async {
                            await repo.addContacts(groupId, [c.id!]);
                            _refresh(ref);
                          }),
                        ));
                      },
                    ),
                  ),
              ]),
      ),
    );
  }
}

/// Multi-select contact picker with search. Returns the chosen ids, or null if cancelled.
Future<Set<int>?> pickContacts(BuildContext context, List<Contact> all,
    {Set<int> exclude = const {}, Set<int> initial = const {}, required String title}) {
  final options = all.where((c) => !exclude.contains(c.id)).toList();
  final chosen = {...initial};
  var query = '';
  return showDialog<Set<int>>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final q = query.toLowerCase();
      final shown = q.isEmpty
          ? options
          : options.where((c) => c.name.toLowerCase().contains(q) || c.phoneRaw.contains(q) ||
              (c.phoneNormalized?.contains(q) ?? false)).toList();
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 400,
          height: 420,
          child: Column(children: [
            TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search'),
              onChanged: (v) => setState(() => query = v),
            ),
            Expanded(
              child: options.isEmpty
                  ? const Center(child: Text('No contacts to add.'))
                  : ListView(children: [
                      for (final c in shown)
                        CheckboxListTile(
                          value: chosen.contains(c.id),
                          title: Text(c.name),
                          subtitle: Text(c.phoneNormalized ?? c.phoneRaw),
                          onChanged: (v) => setState(() => v == true ? chosen.add(c.id!) : chosen.remove(c.id)),
                        ),
                    ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, chosen), child: Text('Done (${chosen.length})')),
        ],
      );
    }),
  );
}
