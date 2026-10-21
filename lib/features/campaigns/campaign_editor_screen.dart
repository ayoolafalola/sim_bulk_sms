import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../groups/group_detail_screen.dart';

/// Create a campaign, or rewrite a draft/ready one. Recipients are re-selected
/// each time: only the saved snapshot is persisted, not the selection.
class CampaignEditorScreen extends ConsumerStatefulWidget {
  const CampaignEditorScreen({super.key, this.campaignId});
  final int? campaignId;

  @override
  ConsumerState<CampaignEditorScreen> createState() => _CampaignEditorScreenState();
}

class _CampaignEditorScreenState extends ConsumerState<CampaignEditorScreen> {
  static const variables = ['first_name', 'name', 'last_name', 'phone', 'email'];

  final _name = TextEditingController();
  final _template = TextEditingController();
  final _groupIds = <int>{};
  final _contactIds = <int>{};
  final _fallbacks = <String, String>{};
  SnapshotPlan? _plan;
  String? _lockedReason;
  bool _loading = true, _saving = false;
  Timer? _debounce;
  int _planSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _template.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.campaignId;
    if (id != null) {
      final c = await ref.read(campaignRepositoryProvider).get(id);
      if (c == null) {
        _lockedReason = 'This campaign no longer exists.';
      } else if (c.status != CampaignStatus.draft && c.status != CampaignStatus.ready) {
        _lockedReason = SnapshotLockedException(c.status.name).toString();
      } else {
        _name.text = c.name;
        _template.text = c.messageTemplate;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _replan() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final seq = ++_planSeq;
      final hasSelection = _groupIds.isNotEmpty || _contactIds.isNotEmpty;
      final plan = (_template.text.trim().isEmpty || !hasSelection)
          ? null
          : await ref.read(composerProvider).plan(
              template: _template.text, groupIds: _groupIds, contactIds: _contactIds,
              fallbacks: {for (final e in _fallbacks.entries) if (e.value.trim().isNotEmpty) e.key: e.value});
      if (mounted && seq == _planSeq) setState(() => _plan = plan);
    });
  }

  void _insertVariable(String v) {
    final sel = _template.selection;
    final text = _template.text;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final token = '{$v}';
    _template.value = TextEditingValue(
      text: text.replaceRange(at, end, token),
      selection: TextSelection.collapsed(offset: at + token.length),
    );
    _replan();
  }

  String _platform() {
    final caps = ref.read(capabilitiesProvider).valueOrNull;
    if (caps != null) return caps.platform == SmsPlatform.ios ? 'ios' : 'android';
    return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  }

  Future<void> _save() async {
    final plan = _plan;
    if (plan == null || !plan.canSave || _name.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final id = await ref.read(composerProvider).save(
          campaignId: widget.campaignId, name: _name.text, template: _template.text,
          platform: _platform(), plan: plan);
      ref.read(dataVersionProvider.notifier).state++;
      if (mounted) context.go('/campaigns/$id');
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.campaignId == null ? 'New campaign' : 'Edit campaign';
    if (_loading) return Scaffold(appBar: AppBar(title: Text(title)), body: const Center(child: CircularProgressIndicator()));
    if (_lockedReason != null) {
      return Scaffold(appBar: AppBar(title: Text(title)), body: Center(child: Text(_lockedReason!)));
    }
    final groups = ref.watch(groupsProvider).valueOrNull ?? const [];
    final plan = _plan;
    final canSave = !_saving && plan != null && plan.canSave && _name.text.trim().isNotEmpty;
    final fallbackKeys = {...?plan?.unresolvedVariables, ..._fallbacks.keys}.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: canSave ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Save and review'),
          ),
        ),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Campaign name', border: OutlineInputBorder()),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _template,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
              labelText: 'Message', alignLabelWithHint: true, border: OutlineInputBorder()),
          onChanged: (_) => _replan(),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final v in variables) ActionChip(label: Text('{$v}'), onPressed: () => _insertVariable(v)),
        ]),
        const SizedBox(height: 24),
        Text('Recipients', style: Theme.of(context).textTheme.titleMedium),
        if (groups.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No groups yet.'))
        else
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final g in groups)
              FilterChip(
                label: Text('${g.name} (${g.memberCount})'),
                selected: _groupIds.contains(g.id),
                onSelected: (on) {
                  setState(() => on ? _groupIds.add(g.id) : _groupIds.remove(g.id));
                  _replan();
                },
              ),
          ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.person_search),
            label: Text(_contactIds.isEmpty
                ? 'Pick individual contacts'
                : '${_contactIds.length} individual ${_contactIds.length == 1 ? 'contact' : 'contacts'} picked'),
            onPressed: () async {
              final all = await ref.read(allContactsProvider.future);
              if (!context.mounted) return;
              final picked = await pickContacts(context, all, initial: _contactIds, title: 'Pick contacts');
              if (picked == null) return;
              setState(() => _contactIds..clear()..addAll(picked));
              _replan();
            },
          ),
        ),
        if (fallbackKeys.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Fallback values', style: Theme.of(context).textTheme.titleMedium),
          const Text('Used when a recipient has no value for a variable.'),
          for (final k in fallbackKeys)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextFormField(
                initialValue: _fallbacks[k],
                decoration: InputDecoration(labelText: '{$k}', border: const OutlineInputBorder()),
                onChanged: (v) {
                  _fallbacks[k] = v;
                  _replan();
                },
              ),
            ),
        ],
        const SizedBox(height: 24),
        if (plan != null) PlanSummary(plan),
      ]),
    );
  }
}

/// What will actually be sent, derived from the plan. Shown before saving.
class PlanSummary extends StatelessWidget {
  const PlanSummary(this.plan, {super.key});
  final SnapshotPlan plan;

  @override
  Widget build(BuildContext context) {
    final e = plan.eligibility;
    final est = plan.estimate;
    final scheme = Theme.of(context).colorScheme;
    Widget line(String s, {Color? color}) =>
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(s, style: TextStyle(color: color)));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${plan.recipients.length} ${plan.recipients.length == 1 ? 'recipient' : 'recipients'}',
              style: Theme.of(context).textTheme.titleLarge),
          if (est.messages > 0)
            line('About ${est.totalSegments} SMS ${est.totalSegments == 1 ? 'segment' : 'segments'} in total '
                '(up to ${est.maxSegments} per message). Carrier charges apply per segment.'),
          if (est.unicodeMessages > 0)
            line('${est.unicodeMessages} messages contain special characters, which shortens each segment.'),
          if (e.excludedSuppressed.isNotEmpty) line('${e.excludedSuppressed.length} excluded: on the suppression list.'),
          if (e.excludedOptedOut.isNotEmpty) line('${e.excludedOptedOut.length} excluded: opted out.'),
          if (e.excludedInvalid.isNotEmpty) line('${e.excludedInvalid.length} excluded: invalid phone number.'),
          if (plan.unknownConsentCount > 0)
            line('${plan.unknownConsentCount} recipients have not confirmed consent.', color: scheme.tertiary),
          if (plan.blocked.isNotEmpty)
            line('${plan.blocked.length} recipients have no value for '
                '${plan.unresolvedVariables.map((v) => '{$v}').join(', ')}. Add a fallback value above to continue.',
                color: scheme.error),
          if (plan.recipients.isEmpty && plan.blocked.isEmpty) line('No one in this selection can be messaged.', color: scheme.error),
          if (plan.recipients.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Preview for ${plan.recipients.first.name}', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
              child: Text(plan.recipients.first.renderedMessage),
            ),
          ],
        ]),
      ),
    );
  }
}
