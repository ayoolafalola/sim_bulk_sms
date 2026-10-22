import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/settings_providers.dart';
import '../../app/theme.dart';
import '../../data/importers/csv_decode.dart';
import '../../data/importers/csv_parser.dart';
import '../../data/repositories/group_repository.dart';
import '../../domain/models/contact.dart';
import '../../domain/models/statuses.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../groups/groups_screen.dart';
import 'csv_import_screen.dart';

/// The Contacts tab: people and groups in one place, with quick ways to bring
/// contacts in. Deletes can be undone for a few seconds instead of asking first.
class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key, this.showGroups = false});
  final bool showGroups;

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  late bool _groups = widget.showGroups;
  final _pendingDelete = <int>{};

  void _refresh() => ref.read(dataVersionProvider.notifier).state++;
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsProvider);
    final groups = ref.watch(groupsProvider);
    final total = ref.watch(dashboardStatsProvider).valueOrNull?.contacts;
    final c = AppColors.of(context);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab-contacts-${widget.showGroups}', // '/contacts' and '/groups' can both be alive
        onPressed: _groups ? _newGroup : _addContact,
        icon: Icon(_groups ? Icons.group_add_outlined : Icons.person_add_alt),
        label: Text(_groups ? 'New group' : 'Add contact'),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          TabTitle('Contacts',
              trailing: total == null ? null : Text('$total people', style: TextStyle(color: c.muted))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(children: [
              _QuickAction(icon: Icons.smartphone, label: 'From phone', onTap: () => context.push('/contacts/import')),
              const SizedBox(width: 8),
              _QuickAction(icon: Icons.description_outlined, label: 'From file', onTap: _importCsv),
              const SizedBox(width: 8),
              _QuickAction(icon: Icons.person_add_alt, label: 'Add one', onTap: _addContact),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('People')),
                ButtonSegment(value: true, label: Text('Groups')),
              ],
              selected: {_groups},
              onSelectionChanged: (v) => setState(() => _groups = v.first),
            ),
          ),
          if (!_groups)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name, number or email'),
                onChanged: (v) => ref.read(contactSearchProvider.notifier).state = v,
              ),
            ),
          Expanded(
            // Material (not a coloured box) so list rows keep their tap ripple.
            child: Material(
              color: c.surface,
              clipBehavior: Clip.antiAlias,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
              child: _groups ? _groupsView(groups) : _peopleView(contacts),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _peopleView(AsyncValue<List<Contact>> contacts) => contacts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Could not load contacts.')),
        data: (all) {
          final list = all.where((x) => !_pendingDelete.contains(x.id)).toList();
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.people_outline,
              title: ref.read(contactSearchProvider).trim().isEmpty ? 'No contacts yet' : 'No matches',
              text: ref.read(contactSearchProvider).trim().isEmpty
                  ? 'Bring in people from your phone or a spreadsheet, or add someone by hand.'
                  : 'Try a different name, number or email.',
              action: ref.read(contactSearchProvider).trim().isEmpty
                  ? FilledButton.icon(
                      onPressed: () => context.push('/contacts/import'),
                      icon: const Icon(Icons.smartphone),
                      label: const Text('Import from phone'))
                  : null,
            );
          }
          return ListView.separated(
            padding: pagePadding(context, extra: fabClearance).copyWith(left: 0, right: 0, top: 8),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(indent: 76),
            itemBuilder: (context, i) => _ContactTile(list[i], onTap: () => _contactActions(list[i])),
          );
        },
      );

  Widget _groupsView(AsyncValue<List<GroupSummary>> groups) => groups.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Could not load groups.')),
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.groups_outlined,
                title: 'No groups yet',
                text: 'Groups let you message many people at once: a choir, a class, your customers.',
                action: FilledButton.icon(
                    onPressed: _newGroup, icon: const Icon(Icons.group_add_outlined), label: const Text('New group')),
              )
            : GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.6,
                padding: pagePadding(context, extra: fabClearance),
                children: [
                  for (final g in list)
                    Material(
                      color: AppColors.of(context).ground,
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => context.push('/groups/${g.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text(g.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 4),
                            Text('${g.memberCount} ${g.memberCount == 1 ? 'person' : 'people'}',
                                style: TextStyle(color: AppColors.of(context).muted)),
                          ]),
                        ),
                      ),
                    ),
                ],
              ),
      );

  Future<void> _newGroup() async {
    final name = await askGroupName(context, title: 'New group');
    if (name == null) return;
    final id = await ref.read(groupRepositoryProvider).create(name);
    _refresh();
    if (mounted) context.push('/groups/$id');
  }

  Future<void> _contactActions(Contact x) async {
    final repo = ref.read(contactRepositoryProvider);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: InitialsAvatar(x.name),
            title: Text(x.name),
            subtitle: Text([x.phoneNormalized ?? x.phoneRaw, if (x.email != null) x.email!].join(' · ')),
          ),
          const Divider(),
          if (x.consent != ConsentStatus.optedIn)
            ListTile(leading: const Icon(Icons.check_circle_outline), title: const Text('Mark as opted in'),
                onTap: () => Navigator.pop(ctx, 'in')),
          if (x.consent != ConsentStatus.optedOut)
            ListTile(leading: const Icon(Icons.do_not_disturb_on_outlined), title: const Text('Mark as opted out'),
                subtitle: const Text('Never included in campaigns'), onTap: () => Navigator.pop(ctx, 'out')),
          if (x.phoneNormalized != null)
            ListTile(leading: const Icon(Icons.block), title: const Text('Add to suppression list'),
                onTap: () => Navigator.pop(ctx, 'suppress')),
          ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete')),
          const SizedBox(height: 8),
        ]),
      ),
    );
    switch (action) {
      case 'in':
        await repo.setConsent(x.id!, ConsentStatus.optedIn);
        _refresh();
      case 'out':
        await repo.setConsent(x.id!, ConsentStatus.optedOut);
        _refresh();
      case 'suppress':
        await repo.suppress(x.phoneNormalized!, reason: 'added manually');
        _snack('${x.name} won\'t receive campaigns.');
      case 'delete':
        _deleteWithUndo(x);
    }
  }

  /// Hidden right away; really deleted only when the Undo snackbar closes.
  void _deleteWithUndo(Contact x) {
    final repo = ref.read(contactRepositoryProvider);
    setState(() => _pendingDelete.add(x.id!));
    final controller = ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Deleted ${x.name}'),
      action: SnackBarAction(label: 'Undo', onPressed: () {}),
    ));
    controller.closed.then((reason) async {
      if (reason == SnackBarClosedReason.action) {
        if (mounted) setState(() => _pendingDelete.remove(x.id));
        return;
      }
      await repo.delete(x.id!);
      if (mounted) {
        setState(() => _pendingDelete.remove(x.id));
        _refresh();
      }
    });
  }

  Future<void> _addContact() async {
    final name = TextEditingController(), phone = TextEditingController(), email = TextEditingController();
    final normalizer = ref.read(phoneNormalizerProvider);
    final repo = ref.read(contactRepositoryProvider);
    String? phoneError;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Add contact', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(controller: name, autofocus: true, textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: 'Phone number', errorText: phoneError)),
            const SizedBox(height: 12),
            TextField(controller: email, keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email (optional)')),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                final n = normalizer.normalize(phone.text);
                if (!n.isValid) {
                  setSheet(() => phoneError = 'This is not a valid phone number.');
                  return;
                }
                try {
                  await repo.add(Contact(
                      name: name.text.trim(), phoneRaw: phone.text.trim(), phoneNormalized: n.e164,
                      email: email.text.trim().isEmpty ? null : email.text.trim()));
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } on DuplicateContactException {
                  setSheet(() => phoneError = 'A contact with this number already exists.');
                }
              },
              child: const Text('Save'),
            ),
          ]),
        ),
      ),
    );
    if (saved == true) _refresh();
  }

  Future<void> _importCsv() async {
    // Excel files are allowed in the picker only to explain how to save them as CSV.
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv', 'txt', 'xlsx', 'xls']);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    final String text;
    try {
      text = decodeCsvBytes(bytes);
    } on CsvFormatException catch (e) {
      _snack(e.message);
      return;
    }
    await context.push('/contacts/import-csv', extra: CsvImportArgs(fileName: picked.name, text: text));
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Material(
          color: AppColors.of(context).surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18), side: BorderSide(color: AppColors.of(context).line)),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
              child: Column(children: [
                Icon(icon, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 6),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
      );
}

class _ContactTile extends StatelessWidget {
  const _ContactTile(this.c, {required this.onTap});
  final Contact c;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = [
      c.phoneNormalized ?? c.phoneRaw,
      if (c.email != null && c.email!.isNotEmpty) c.email!,
      if (c.consent == ConsentStatus.optedOut) 'Opted out',
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: InitialsAvatar(c.name),
      title: Text(c.name),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (c.phoneNormalized != null) const StatusTag('SMS', tone: Tone.success),
        if (c.email != null && c.email!.isNotEmpty) ...[const SizedBox(width: 4), const StatusTag('Email', tone: Tone.info)],
      ]),
      onTap: onTap,
    );
  }
}
