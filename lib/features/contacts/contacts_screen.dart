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
import '../../domain/models/channels.dart';
import '../../domain/models/contact.dart';
import '../../domain/models/statuses.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../groups/groups_screen.dart';
import 'contact_sync_runner.dart';
import 'csv_import_screen.dart';

/// The Contacts tab: people and groups in one place. Once allowed, the phone's
/// contacts are synced in automatically; files and hand-added people stay app-only.
/// Tap a person for their details; long-press (or Select) to pick several and add
/// them to a group. Deletes can be undone for a few seconds instead of asking first.
class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key, this.showGroups = false});
  final bool showGroups;

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  late bool _groups = widget.showGroups;
  final _pendingDelete = <int>{};
  Set<int>? _selected; // null = not selecting

  void _refresh() => ref.read(dataVersionProvider.notifier).state++;
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final contacts = ref.watch(contactsProvider);
    final groups = ref.watch(groupsProvider);
    final total = ref.watch(dashboardStatsProvider).valueOrNull?.contacts;
    final c = AppColors.of(context);
    final syncMode = ref.watch(contactsSyncModeProvider);
    final syncOn = syncMode.valueOrNull == true;
    final selected = _selected;

    return PopScope(
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selected = null);
      },
      child: Scaffold(
        bottomNavigationBar: selected == null ? null : _selectionBar(selected, contacts.valueOrNull ?? const []),
        floatingActionButton: selected != null
            ? null
            : FloatingActionButton.extended(
                heroTag: 'fab-contacts-${widget.showGroups}', // '/contacts' and '/groups' can both be alive
                onPressed: _groups ? _newGroup : _addContact,
                icon: Icon(_groups ? Icons.group_add_outlined : Icons.person_add_alt),
                label: Text(_groups ? 'New group' : 'Add contact'),
              ),
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            if (selected != null)
              TabTitle('${selected.length} selected',
                  trailing: IconButton(
                      tooltip: 'Done',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _selected = null)))
            else
              TabTitle('Contacts',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (total != null) Text('$total people', style: TextStyle(color: c.muted)),
                    if (!_groups)
                      IconButton(
                          tooltip: 'Select',
                          icon: const Icon(Icons.checklist),
                          onPressed: () => setState(() => _selected = {})),
                  ])),
            if (selected == null && syncMode.hasValue && syncMode.value == null) _syncConsentCard(),
            if (selected == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(children: [
                  if (!syncOn) ...[
                    _QuickAction(
                        icon: Icons.smartphone, label: 'From phone', onTap: () => context.push('/contacts/import')),
                    const SizedBox(width: 8),
                  ],
                  _QuickAction(icon: Icons.description_outlined, label: 'From file', onTap: _importCsv),
                  const SizedBox(width: 8),
                  _QuickAction(icon: Icons.person_add_alt, label: 'Add one', onTap: _addContact),
                ]),
              ),
            if (selected == null)
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
                  decoration:
                      const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name, number or email'),
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
      ),
    );
  }

  Widget _syncConsentCard() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Use your phone\'s contacts?', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('Everyone in your phone\'s Contacts appears here and stays up to date: numbers, emails, '
                  'birthdays and more. Nothing is uploaded; it stays on this phone.'),
              OverflowBar(alignment: MainAxisAlignment.end, spacing: 4, children: [
                TextButton(
                    onPressed: () => ref.read(contactSyncRunnerProvider).disable(), child: const Text('Not now')),
                FilledButton(onPressed: _enableSync, child: const Text('Use phone contacts')),
              ]),
            ]),
          ),
        ),
      );

  Future<void> _enableSync() async {
    final result = await ref.read(contactSyncRunnerProvider).enable();
    if (!mounted) return;
    if (result == null && !await ref.read(phoneContactsServiceProvider).hasPermission()) {
      _snack('Allow Contacts access to use your phone\'s contacts.');
    } else if (result != null) {
      _snack('${result.added + result.updated} contacts from your phone are here.');
    }
    _refresh();
  }

  Widget _selectionBar(Set<int> selected, List<Contact> all) {
    final visible = all.where((x) => !_pendingDelete.contains(x.id)).map((x) => x.id!).toSet();
    final allSelected = visible.isNotEmpty && selected.containsAll(visible);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() => _selected = allSelected ? {} : visible),
              child: Text(allSelected ? 'Clear' : 'Select all'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: selected.isEmpty ? null : () => _addSelectedToGroup(selected),
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Add to group'),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _addSelectedToGroup(Set<int> ids) async {
    final groups = await ref.read(groupsProvider.future);
    if (!mounted) return;
    final gid = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Add to group'), children: [
        for (final g in groups) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, g.id), child: Text(g.name)),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, -1),
          child: Row(children: [
            Icon(Icons.add, size: 20, color: Theme.of(ctx).colorScheme.primary),
            const SizedBox(width: 8),
            const Text('New group'),
          ]),
        ),
      ]),
    );
    if (gid == null || !mounted) return;
    var target = gid;
    if (gid == -1) {
      final name = await askGroupName(context, title: 'New group');
      if (name == null) return;
      target = await ref.read(groupRepositoryProvider).create(name);
    }
    await ref.read(groupRepositoryProvider).addContacts(target, ids);
    if (!mounted) return;
    setState(() => _selected = null);
    _refresh();
    _snack('Added ${ids.length} ${ids.length == 1 ? 'person' : 'people'} to the group.');
  }

  Future<void> _openContact(Contact x) async {
    final r = await context.push<String>('/contacts/person/${x.id}');
    if (r == 'delete' && mounted) _deleteWithUndo(x);
  }

  void _toggle(Contact x) => setState(() {
        final s = _selected!;
        if (!s.remove(x.id)) s.add(x.id!);
      });

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
              action: ref.read(contactSearchProvider).trim().isEmpty &&
                      ref.read(contactsSyncModeProvider).valueOrNull != true
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
            itemBuilder: (context, i) {
              final x = list[i];
              final selected = _selected;
              return _ContactTile(
                x,
                selected: selected?.contains(x.id),
                onTap: () => selected != null ? _toggle(x) : _openContact(x),
                onLongPress: selected != null ? null : () => setState(() => _selected = {x.id!}),
              );
            },
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
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(g.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
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
            TextField(
                controller: name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: 'Phone number', errorText: phoneError)),
            const SizedBox(height: 12),
            TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                final n = phone.text.trim().isEmpty ? null : normalizer.normalize(phone.text);
                if (n != null && !n.isValid) {
                  setSheet(() => phoneError = 'This is not a valid phone number.');
                  return;
                }
                if (n == null && !isValidEmail(email.text)) {
                  setSheet(() => phoneError = 'Add a phone number or an email address.');
                  return;
                }
                try {
                  await repo.add(Contact(
                      name: name.text.trim(),
                      phoneRaw: phone.text.trim(),
                      phoneNormalized: n?.e164,
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
                Text(label,
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
      );
}

class _ContactTile extends StatelessWidget {
  const _ContactTile(this.c, {required this.onTap, this.onLongPress, this.selected});
  final Contact c;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool? selected; // null = not in select mode

  @override
  Widget build(BuildContext context) {
    final sub = [
      if ((c.phoneNormalized ?? c.phoneRaw).isNotEmpty) c.phoneNormalized ?? c.phoneRaw,
      if (c.email != null && c.email!.isNotEmpty) c.email!,
      if (c.consent == ConsentStatus.optedOut) 'Opted out',
    ].join(' · ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: selected == null
          ? InitialsAvatar(c.name)
          : SizedBox(width: 44, child: Checkbox(value: selected, onChanged: (_) => onTap())),
      selected: selected ?? false,
      title: Text(c.name),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (c.phoneNormalized != null) const StatusTag('SMS', tone: Tone.success),
        if (c.email != null && c.email!.isNotEmpty) ...[
          const SizedBox(width: 4),
          const StatusTag('Email', tone: Tone.info)
        ],
      ]),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
