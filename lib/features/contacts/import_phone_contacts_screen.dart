import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/settings_providers.dart';
import '../../platform/contacts/phone_contacts_service.dart';
import '../groups/groups_screen.dart';

/// Indices of [all] whose name or number matches [query]. Number matching
/// ignores spaces, dashes and brackets, so "0803 123" finds "+234 803-123-...".
List<int> filterPhoneContacts(List<PhoneContact> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return [for (var i = 0; i < all.length; i++) i];
  final qDigits = q.replaceAll(RegExp(r'\D'), '');
  // A local trunk "0" is dropped in international form (0803... vs +234803...).
  final qLocal = qDigits.replaceFirst(RegExp('^0'), '');
  final out = <int>[];
  for (var i = 0; i < all.length; i++) {
    final c = all[i];
    final digits = c.phone.replaceAll(RegExp(r'\D'), '');
    final numberMatch = qDigits.isNotEmpty &&
        (digits.contains(qDigits) || (qLocal.length >= 3 && digits.contains(qLocal)));
    if (c.name.toLowerCase().contains(q) || numberMatch) out.add(i);
  }
  return out;
}

/// Load the phone's contacts, search, select (or select all shown) and add
/// them to a group. Selected people are saved as app contacts first; numbers
/// that are already app contacts are reused.
class ImportPhoneContactsScreen extends ConsumerStatefulWidget {
  const ImportPhoneContactsScreen({super.key, this.groupId});
  /// When set, selected contacts go straight into this group.
  final int? groupId;

  @override
  ConsumerState<ImportPhoneContactsScreen> createState() => _ImportPhoneContactsScreenState();
}

enum _Phase { loading, denied, error, ready }

class _ImportPhoneContactsScreenState extends ConsumerState<ImportPhoneContactsScreen> {
  _Phase _phase = _Phase.loading;
  String? _error;
  List<PhoneContact> _all = const [];
  List<int> _shown = const [];
  final _selected = <int>{};
  String _query = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool ask = true}) async {
    setState(() => _phase = _Phase.loading);
    final svc = ref.read(phoneContactsServiceProvider);
    try {
      var ok = await svc.hasPermission();
      if (!ok && ask) ok = await svc.requestPermission();
      if (!ok) {
        if (mounted) setState(() => _phase = _Phase.denied);
        return;
      }
      final all = await svc.load();
      if (!mounted) return;
      setState(() {
        _all = all;
        _shown = filterPhoneContacts(all, _query);
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (mounted) setState(() { _phase = _Phase.error; _error = '$e'; });
    }
  }

  void _search(String q) => setState(() {
        _query = q;
        _shown = filterPhoneContacts(_all, q);
      });

  bool? get _allShownSelected {
    if (_shown.isEmpty) return false;
    final n = _shown.where(_selected.contains).length;
    return n == 0 ? false : n == _shown.length ? true : null;
  }

  void _toggleAllShown() => setState(() {
        if (_allShownSelected == true) {
          _selected.removeAll(_shown);
        } else {
          _selected.addAll(_shown);
        }
      });

  Future<int?> _chooseGroup() async {
    final groups = await ref.read(groupsProvider.future);
    if (!mounted) return null;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Add to which group?'), children: [
        for (final g in groups)
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, g.id), child: Text('${g.name} (${g.memberCount})')),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, -1),
          child: const Row(children: [Icon(Icons.add), SizedBox(width: 8), Text('New group…')]),
        ),
      ]),
    );
    if (picked != -1 || !mounted) return picked;
    final name = await askGroupName(context, title: 'New group');
    if (name == null) return null;
    final id = await ref.read(groupRepositoryProvider).create(name);
    ref.read(dataVersionProvider.notifier).state++;
    return id;
  }

  Future<void> _addToGroup() async {
    final groupId = widget.groupId ?? await _chooseGroup();
    if (groupId == null || !mounted) return;
    setState(() => _saving = true);
    final normalizer = ref.read(phoneNormalizerProvider);
    final entries = <({String name, String phoneRaw, String e164})>[];
    var invalid = 0;
    for (final i in _selected) {
      final c = _all[i];
      final n = normalizer.normalize(c.phone);
      if (n.isValid) {
        entries.add((name: c.name, phoneRaw: c.phone, e164: n.e164!));
      } else {
        invalid++;
      }
    }
    try {
      final res = await ref.read(contactRepositoryProvider).upsertByPhone(entries);
      await ref.read(groupRepositoryProvider).addContacts(groupId, res.ids);
      ref.read(dataVersionProvider.notifier).state++;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Added ${res.ids.length} to the group. New contacts: ${res.added}, '
            'already saved: ${res.existing}${invalid > 0 ? ', skipped (invalid number): $invalid' : ''}.'),
      ));
      if (widget.groupId != null) {
        context.pop();
      } else {
        context.go('/groups/$groupId');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nothing was added: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import from phone')),
      body: switch (_phase) {
        _Phase.loading => const Center(child: CircularProgressIndicator()),
        _Phase.denied => _Message(
            'Contacts access is needed to read names and numbers from your phone.',
            action: FilledButton(onPressed: _load, child: const Text('Allow access'))),
        _Phase.error => _Message('Could not read your phone contacts.\n$_error',
            action: FilledButton(onPressed: _load, child: const Text('Try again'))),
        _Phase.ready => Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: TextField(
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: 'Search name or number', border: OutlineInputBorder()),
                onChanged: _search,
              ),
            ),
            CheckboxListTile(
              tristate: true,
              value: _allShownSelected,
              onChanged: _shown.isEmpty ? null : (_) => _toggleAllShown(),
              title: Text(_query.trim().isEmpty ? 'Select all (${_shown.length})' : 'Select all matches (${_shown.length})'),
              subtitle: Text('${_selected.length} selected'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const Divider(height: 1),
            Expanded(
              child: _all.isEmpty
                  ? const _Message('No contacts with phone numbers were found on this phone.')
                  : _shown.isEmpty
                      ? const _Message('No contacts match your search.')
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 24),
                          itemCount: _shown.length,
                          itemBuilder: (context, k) {
                            final i = _shown[k];
                            final c = _all[i];
                            return CheckboxListTile(
                              value: _selected.contains(i),
                              onChanged: (v) => setState(() => v == true ? _selected.add(i) : _selected.remove(i)),
                              title: Text(c.name.isEmpty ? c.phone : c.name),
                              subtitle: Text(c.phone),
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
            ),
            // In the body (not the bottom bar) so it stays above the keyboard while searching.
            Material(
              elevation: 3,
              color: Theme.of(context).colorScheme.surface,
              child: SafeArea(
                top: false,
                bottom: MediaQuery.viewInsetsOf(context).bottom == 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _selected.isEmpty || _saving ? null : _addToGroup,
                      icon: const Icon(Icons.group_add),
                      label: Text(_saving ? 'Adding…' : 'Add ${_selected.length} to group'),
                    ),
                  ),
                ),
              ),
            ),
          ]),
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.action});
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}
