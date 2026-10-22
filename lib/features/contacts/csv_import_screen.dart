import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/settings_providers.dart';
import '../../core/phone_numbers/phone_normalizer.dart';
import '../../data/importers/contact_import_planner.dart';
import '../../data/importers/csv_parser.dart';
import '../common/page_layout.dart';
import '../groups/groups_screen.dart';

/// A picked CSV file, already decoded to text.
class CsvImportArgs {
  const CsvImportArgs({required this.fileName, required this.text});
  final String fileName, text;
}

/// Most rows one import handles (larger files: split them).
const maxImportRows = 20000;

/// Above this many rows, parsing and planning run off the UI thread.
const _backgroundThreshold = 3000;

class _PlanJob {
  const _PlanJob(this.table, this.mapping, this.region, this.existing, this.hasHeader, this.useNumberAsName);
  final List<List<String>> table;
  final ColumnMapping mapping;
  final String region;
  final Set<String> existing;
  final bool hasHeader, useNumberAsName;
}

ImportPlan _runPlan(_PlanJob j) => planImport(
    table: j.table, mapping: j.mapping, normalizer: PhoneNormalizer(j.region), existingNormalized: j.existing,
    hasHeader: j.hasHeader, useNumberAsName: j.useNumberAsName);

String columnLetter(int i) {
  var n = i + 1, s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

String importRowReason(ImportRow r) => switch (r.status) {
      ImportRowStatus.valid => 'OK',
      ImportRowStatus.invalidPhone => r.phoneRaw.isEmpty ? 'No phone number' : 'Not a valid number',
      ImportRowStatus.missingName => 'No name',
      ImportRowStatus.duplicateInFile => 'Same number earlier in the file',
      ImportRowStatus.duplicateExisting => 'Already in your contacts',
    };

/// Map the file's columns, preview what will be saved, optionally add
/// everyone to a group, then import in one go.
class CsvImportScreen extends ConsumerStatefulWidget {
  const CsvImportScreen({super.key, required this.args});
  final CsvImportArgs args;

  @override
  ConsumerState<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends ConsumerState<CsvImportScreen> {
  String? _error;
  List<List<String>>? _table;
  String _delimiter = ',';
  bool _hasHeader = true;
  ColumnMapping? _mapping;
  bool _splitName = false;
  bool _useNumberAsName = false;
  Set<String> _existing = const {};
  ImportPlan? _plan;
  int _planSeq = 0;
  int? _groupId;           // existing group, or null
  String? _newGroupName;   // set when "New group…" was chosen
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(defaultRegionProvider, (_, __) => _replan());
    _load();
  }

  PhoneNormalizer get _normalizer => ref.read(phoneNormalizerProvider);

  Future<void> _load() async {
    try {
      final text = widget.args.text;
      final table = text.length > 200000 ? await compute(parseCsv, text) : parseCsv(text);
      if (table.isEmpty) throw CsvFormatException('The file is empty.');
      if (table.length > maxImportRows + 1) {
        throw CsvFormatException('This file has ${table.length} rows. Import at most $maxImportRows at a time: '
            'split the file and import each part.');
      }
      _existing = await ref.read(contactRepositoryProvider).existingNormalized();
      _delimiter = detectDelimiter(text);
      _table = table;
      _hasHeader = ColumnMapping.looksLikeHeader(table.first, _normalizer);
      _guess();
      if (mounted) setState(() {});
      await _replan();
    } on CsvFormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _guess() {
    _mapping = ColumnMapping.guess(_table!, hasHeader: _hasHeader, normalizer: _normalizer);
    _splitName = _mapping != null && _mapping!.name == null && (_mapping!.firstName != null || _mapping!.lastName != null);
  }

  Future<void> _replan() async {
    final table = _table, mapping = _mapping;
    if (table == null || mapping == null) {
      if (mounted) setState(() => _plan = null);
      return;
    }
    final seq = ++_planSeq;
    final job = _PlanJob(table, mapping, ref.read(defaultRegionProvider), _existing, _hasHeader, _useNumberAsName);
    final plan = table.length > _backgroundThreshold ? await compute(_runPlan, job) : _runPlan(job);
    if (mounted && seq == _planSeq) setState(() => _plan = plan);
  }

  void _setMapping(ColumnMapping m) {
    setState(() => _mapping = m);
    _replan();
  }

  int get _width => _table!.map((r) => r.length).reduce((a, b) => a > b ? a : b);

  String _columnLabel(int c) {
    final t = _table!;
    final header = _hasHeader && c < t.first.length ? t.first[c].trim() : '';
    final sample = t.skip(_hasHeader ? 1 : 0).map((r) => c < r.length ? r[c].trim() : '').firstWhere(
          (v) => v.isNotEmpty, orElse: () => '');
    final shortSample = sample.length > 22 ? '${sample.substring(0, 22)}…' : sample;
    return '${columnLetter(c)}${header.isEmpty ? '' : ' · $header'}${shortSample.isEmpty ? '' : ' ($shortSample)'}';
  }

  Widget _columnPicker(String label, int? value, ValueChanged<int?> onChanged, {bool optional = true}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: DropdownButtonFormField<int?>(
          // Keyed by value: re-guessing the columns rebuilds the field with the new choice.
          key: ValueKey('$label/$value/$_hasHeader'),
          isExpanded: true,
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: [
            if (optional) const DropdownMenuItem<int?>(value: null, child: Text('— None —')),
            for (var c = 0; c < _width; c++)
              DropdownMenuItem<int?>(value: c, child: Text(_columnLabel(c), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged,
        ),
      );

  Future<void> _pickGroup(int? v) async {
    if (v != -1) {
      setState(() { _groupId = v; _newGroupName = null; });
      return;
    }
    final name = await askGroupName(context, title: 'New group');
    if (name == null) return;
    setState(() { _groupId = null; _newGroupName = name; });
  }

  bool get _hasGroup => _groupId != null || _newGroupName != null;

  Future<void> _import() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() => _saving = true);
    try {
      final res = await ref.read(contactRepositoryProvider).commitImportToGroup(plan,
          groupId: _groupId, newGroupName: _newGroupName);
      ref.read(dataVersionProvider.notifier).state++;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          'Imported ${res.added} new ${res.added == 1 ? 'contact' : 'contacts'}.'
          '${res.groupId != null ? ' ${res.inGroup} ${res.inGroup == 1 ? 'is' : 'are'} now in the group.' : ''}')));
      if (res.groupId != null) {
        context.go('/groups/${res.groupId}');
      } else {
        context.pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed. Nothing was saved. ($e)')));
    }
  }

  void _showSkipped(ImportPlan plan) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (ctx, scroll) => ListView(controller: scroll, padding: pagePadding(ctx), children: [
            Text('Skipped rows (${plan.skipped.length})', style: Theme.of(ctx).textTheme.titleMedium),
            for (final r in plan.skipped)
              ListTile(
                dense: true,
                title: Text('Line ${r.line}: ${r.name.isEmpty ? '(no name)' : r.name}'),
                subtitle: Text('${r.phoneRaw.isEmpty ? '' : '${r.phoneRaw} · '}${importRowReason(r)}'),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final title = Text('Import ${widget.args.fileName}', overflow: TextOverflow.ellipsis);
    if (_error != null) {
      return Scaffold(
          appBar: AppBar(title: title),
          body: Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(_error!, textAlign: TextAlign.center))));
    }
    final table = _table;
    if (table == null) return Scaffold(appBar: AppBar(title: title), body: const Center(child: CircularProgressIndicator()));

    final m = _mapping;
    final plan = _plan;
    final groups = ref.watch(groupsProvider).valueOrNull ?? const [];
    final region = ref.watch(defaultRegionProvider);
    final scheme = Theme.of(context).colorScheme;
    final dataRows = table.length - (_hasHeader ? 1 : 0);
    final sep = switch (_delimiter) { ';' => 'semicolons', '\t' => 'tabs', _ => 'commas' };
    final canImport = !_saving && plan != null && (plan.valid > 0 || (_hasGroup && plan.existing.isNotEmpty));
    final groupName = _newGroupName ?? groups.where((g) => g.id == _groupId).firstOrNull?.name;

    return Scaffold(
      appBar: AppBar(title: title),
      body: FormPage(
        action: FilledButton(
          onPressed: canImport ? _import : null,
          child: Text(_saving
              ? 'Importing…'
              : plan == null
                  ? 'Import'
                  : 'Import ${plan.valid} ${plan.valid == 1 ? 'contact' : 'contacts'}${groupName == null ? '' : ' into $groupName'}'),
        ),
        children: [
          Text('$dataRows rows · columns separated by $sep', style: Theme.of(context).textTheme.bodySmall),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('First row is headers'),
            subtitle: _hasHeader ? Text(table.first.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis) : null,
            value: _hasHeader,
            onChanged: (v) {
              setState(() { _hasHeader = v; _guess(); });
              _replan();
            },
          ),
          const SizedBox(height: 8),
          Text('Columns', style: Theme.of(context).textTheme.titleMedium),
          if (m == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('No column looks like phone numbers. Pick the phone column below.',
                  style: TextStyle(color: scheme.error)),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('First and last names are in separate columns'),
            value: _splitName,
            onChanged: m == null
                ? null
                : (v) {
                    setState(() => _splitName = v);
                    _setMapping(v
                        ? m.copyWith(name: () => null, firstName: () => m.firstName ?? m.name, lastName: () => m.lastName)
                        : m.copyWith(name: () => m.name ?? m.firstName, firstName: () => null, lastName: () => null));
                  },
          ),
          if (_splitName) ...[
            _columnPicker('First name', m?.firstName, (v) => _setMapping(m!.copyWith(firstName: () => v))),
            _columnPicker('Last name', m?.lastName, (v) => _setMapping(m!.copyWith(lastName: () => v))),
          ] else
            _columnPicker('Name', m?.name, (v) => m == null ? null : _setMapping(m.copyWith(name: () => v))),
          _columnPicker('Phone number', m?.phone, optional: false, (v) {
            if (v == null) return;
            _setMapping(m == null ? ColumnMapping(phone: v) : m.copyWith(phone: v));
          }),
          _columnPicker('Email (optional)', m?.email, (v) => m == null ? null : _setMapping(m.copyWith(email: () => v))),
          const SizedBox(height: 16),
          if (plan != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Will import ${plan.valid} new', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text([
                    if (plan.existing.isNotEmpty) '${plan.existing.length} already in your contacts',
                    if (plan.repeatedInFile > 0) '${plan.repeatedInFile} repeated in the file',
                    if (plan.invalidPhones > 0) '${plan.invalidPhones} invalid numbers',
                    if (plan.missingNames > 0) '${plan.missingNames} without a name',
                    if (plan.skippedBlank > 0) '${plan.skippedBlank} blank rows',
                  ].join(' · ')),
                  if (plan.multiNumberCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('${plan.multiNumberCount} rows have more than one number; only the first is used.',
                          style: TextStyle(color: scheme.tertiary)),
                    ),
                  if (plan.regionAssumedCount > 0)
                    Row(children: [
                      Expanded(
                          child: Text('Numbers without +code are read as $region numbers.',
                              style: Theme.of(context).textTheme.bodySmall)),
                      TextButton(onPressed: () => context.push('/settings/send'), child: const Text('Change')),
                    ]),
                  if (plan.skipped.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: () => _showSkipped(plan),
                      child: Text('See skipped rows (${plan.skipped.length})'),
                    ),
                  const Divider(),
                  Text('Preview', style: Theme.of(context).textTheme.labelLarge),
                  for (final r in plan.rows.take(5))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        r.status == ImportRowStatus.valid ? Icons.check_circle_outline : Icons.remove_circle_outline,
                        color: r.status == ImportRowStatus.valid ? scheme.primary : scheme.outline,
                      ),
                      title: Text(r.name.isEmpty ? '(no name)' : r.name),
                      subtitle: Text(r.status == ImportRowStatus.valid ? r.e164! : '${r.phoneRaw} · ${importRowReason(r)}'),
                    ),
                ]),
              ),
            ),
            if (plan.missingNames > 0 || _useNumberAsName)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Use the phone number as the name'),
                subtitle: const Text('For rows that have a number but no name.'),
                value: _useNumberAsName,
                onChanged: (v) {
                  setState(() => _useNumberAsName = v);
                  _replan();
                },
              ),
          ],
          const SizedBox(height: 8),
          DropdownButtonFormField<int?>(
            key: ValueKey('group/$_groupId/$_newGroupName'),
            isExpanded: true,
            initialValue: _newGroupName != null ? -1 : _groupId,
            decoration: const InputDecoration(labelText: 'Add everyone to a group (optional)'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('No group')),
              for (final g in groups) DropdownMenuItem<int?>(value: g.id, child: Text('${g.name} (${g.memberCount})')),
              DropdownMenuItem<int?>(value: -1, child: Text(_newGroupName == null ? 'New group…' : 'New group: $_newGroupName')),
            ],
            onChanged: _pickGroup,
          ),
          if (_hasGroup && plan != null && plan.existing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('The ${plan.existing.length} already in your contacts are added to the group too.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
