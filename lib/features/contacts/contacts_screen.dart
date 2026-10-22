import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/settings_providers.dart';
import '../../data/importers/contact_import_planner.dart';
import '../../data/importers/csv_parser.dart';
import '../../domain/models/contact.dart';
import '../../domain/models/statuses.dart';
import '../common/page_layout.dart';

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  void _refresh(WidgetRef ref) => ref.read(dataVersionProvider.notifier).state++;
  void _snack(BuildContext c, String m) =>
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(contactsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts'), actions: [
        IconButton(
            tooltip: 'Import from phone',
            icon: const Icon(Icons.contact_phone_outlined),
            onPressed: () => context.push('/contacts/import')),
        IconButton(
            tooltip: 'Import CSV',
            icon: const Icon(Icons.upload_file),
            onPressed: () => _importCsv(context, ref)),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _addContact(context, ref),
          icon: const Icon(Icons.person_add),
          label: const Text('Add')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: 'Search name or number', border: OutlineInputBorder()),
            onChanged: (v) => ref.read(contactSearchProvider.notifier).state = v,
          ),
        ),
        Expanded(
          child: contacts.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => const Center(child: Text('Could not load contacts.')),
            data: (list) => list.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('No contacts yet. Add one, import a CSV file, or'),
                      TextButton.icon(
                          onPressed: () => context.push('/contacts/import'),
                          icon: const Icon(Icons.contact_phone_outlined),
                          label: const Text('Import from phone')),
                    ]),
                  )
                : ListView.builder(
                    padding: pagePadding(context, extra: fabClearance).copyWith(left: 0, right: 0, top: 0),
                    itemCount: list.length,
                    itemBuilder: (context, i) => _ContactTile(list[i], onChanged: () => _refresh(ref)),
                  ),
          ),
        ),
      ]),
    );
  }

  Future<void> _addContact(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(), phone = TextEditingController();
    final normalizer = ref.read(phoneNormalizerProvider);
    final repo = ref.read(contactRepositoryProvider);
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add contact'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: 'Phone number', errorText: error)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final n = normalizer.normalize(phone.text);
                if (name.text.trim().isEmpty) {
                  setState(() => error = null);
                  return;
                }
                if (!n.isValid) {
                  setState(() => error = 'This is not a valid phone number.');
                  return;
                }
                try {
                  await repo.add(Contact(
                      name: name.text.trim(), phoneRaw: phone.text.trim(), phoneNormalized: n.e164));
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } on DuplicateContactException {
                  setState(() => error = 'A contact with this number already exists.');
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) _refresh(ref);
  }

  Future<void> _importCsv(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv', 'txt']);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!context.mounted) return;

    final List<List<String>> table;
    try {
      table = parseCsv(utf8.decode(bytes, allowMalformed: true));
    } on CsvFormatException catch (e) {
      _snack(context, e.message);
      return;
    }
    final mapping = table.isEmpty ? null : ColumnMapping.suggest(table.first);
    if (mapping == null) {
      _snack(context, 'The first row must have headers including a name column and a phone column.');
      return;
    }
    final repo = ref.read(contactRepositoryProvider);
    final plan = planImport(
      table: table,
      mapping: mapping,
      normalizer: ref.read(phoneNormalizerProvider),
      existingNormalized: await repo.existingNormalized(),
    );
    if (!context.mounted) return;
    final region = ref.read(defaultRegionProvider);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import preview'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Valid: ${plan.valid}'),
          Text('Invalid: ${plan.invalid}'),
          Text('Duplicates: ${plan.duplicates}'),
          Text('Blank rows skipped: ${plan.skippedBlank}'),
          if (plan.regionAssumedCount > 0) ...[
            const SizedBox(height: 8),
            Text('${plan.regionAssumedCount} numbers had no country code and were read as $region numbers.'),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: plan.valid == 0 ? null : () => Navigator.pop(ctx, true),
              child: Text('Import ${plan.valid}')),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    try {
      final n = await repo.commitImport(plan);
      _refresh(ref);
      if (context.mounted) _snack(context, 'Imported $n contacts.');
    } catch (_) {
      if (context.mounted) _snack(context, 'Import failed. Nothing was saved.');
    }
  }
}

class _ContactTile extends ConsumerWidget {
  const _ContactTile(this.c, {required this.onChanged});
  final Contact c;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(contactRepositoryProvider);
    return ListTile(
      title: Text(c.name),
      subtitle: Text('${c.phoneNormalized ?? c.phoneRaw} · ${c.consent.name}'),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          switch (v) {
            case 'in':
              await repo.setConsent(c.id!, ConsentStatus.optedIn);
            case 'out':
              await repo.setConsent(c.id!, ConsentStatus.optedOut);
            case 'suppress':
              if (c.phoneNormalized != null) await repo.suppress(c.phoneNormalized!, reason: 'added manually');
            case 'delete':
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete contact?'),
                  content: Text('${c.name} will be removed. Existing campaign records keep their own copy.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) await repo.delete(c.id!);
          }
          onChanged();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'in', child: Text('Mark as opted in')),
          PopupMenuItem(value: 'out', child: Text('Mark as opted out')),
          PopupMenuItem(value: 'suppress', child: Text('Add to suppression list')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
