import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../data/repositories/campaign_repository.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/channels.dart';
import '../../domain/models/pro.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../common/page_layout.dart';
import '../pro/pro_screen.dart';
import '../groups/group_detail_screen.dart';
import 'message_counter.dart';

/// Create a campaign, or rewrite a draft/ready one. The selection (groups and
/// contacts) and fallbacks are saved with it and restored when editing.
///
/// New campaigns and drafts are autosaved as a `draft` shortly after each
/// change, so nothing typed is lost. A `ready` campaign is never silently
/// turned back into a draft: its edits are kept in the form until "Save and
/// review", and leaving with unsaved edits asks first.
class CampaignEditorScreen extends ConsumerStatefulWidget {
  const CampaignEditorScreen({super.key, this.campaignId});
  final int? campaignId;

  @override
  ConsumerState<CampaignEditorScreen> createState() => _CampaignEditorScreenState();
}

class _CampaignEditorScreenState extends ConsumerState<CampaignEditorScreen> {
  static const variables = ['first_name', 'name', 'last_name', 'phone', 'email', 'company', 'birthday'];
  static const untitled = 'Untitled draft';

  final _name = TextEditingController();
  final _template = TextEditingController();
  final _subject = TextEditingController();
  SendChannel _channel = SendChannel.sms;
  final _groupIds = <int>{};
  final _contactIds = <int>{};
  final _fallbacks = <String, String>{};
  SnapshotPlan? _plan;
  String? _lockedReason;
  bool _loading = true, _saving = false;
  Timer? _debounce;
  int _planSeq = 0;

  // Autosave (new campaigns and drafts).
  late final CampaignRepository _repo;
  late final StateController<int> _version;
  late String _platformName;
  int? _draftId;
  bool _autosave = true;
  bool _pending = false; // changes not yet written
  bool _dirty = false;   // ready campaign edited but not saved
  Timer? _autosaveTimer;
  Future<void> _flushing = Future<void>.value();
  DateTime? _savedAt;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(campaignRepositoryProvider);
    _version = ref.read(dataVersionProvider.notifier);
    _platformName = _platform();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _autosaveTimer?.cancel();
    // Leaving the screen: write any last changes (the repository outlives the widget).
    if (_autosave && _pending) _flush();
    _name.dispose();
    _template.dispose();
    _subject.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.campaignId;
    if (id != null) {
      final c = await _repo.get(id);
      if (c == null) {
        _lockedReason = 'This campaign no longer exists.';
      } else if (c.status != CampaignStatus.draft && c.status != CampaignStatus.ready) {
        _lockedReason = SnapshotLockedException(c.status.name).toString();
      } else {
        _draftId = c.status == CampaignStatus.draft ? id : null;
        _autosave = c.status == CampaignStatus.draft;
        _name.text = c.name == untitled ? '' : c.name;
        _template.text = c.messageTemplate;
        _channel = c.channel;
        _subject.text = c.subject ?? '';
        final a = await _repo.audience(id);
        _groupIds.addAll(a.groupIds);
        _contactIds.addAll(a.contactIds);
        _fallbacks.addAll(await _repo.fallbacks(id));
      }
    }
    if (mounted) setState(() => _loading = false);
    _replan();
  }

  /// Every edit goes through here.
  void _changed() {
    _replan();
    if (_autosave) {
      _pending = true;
      _autosaveTimer?.cancel();
      _autosaveTimer = Timer(const Duration(milliseconds: 700), _flush);
    } else if (!_dirty) {
      setState(() => _dirty = true);
    }
  }

  String? get _subjectOrNull => _channel.usesEmail && _subject.text.trim().isNotEmpty ? _subject.text.trim() : null;

  Map<String, String> get _cleanFallbacks =>
      {for (final e in _fallbacks.entries) if (e.value.trim().isNotEmpty) e.key: e.value};

  bool get _isEmpty =>
      _name.text.trim().isEmpty && _template.text.trim().isEmpty && _groupIds.isEmpty && _contactIds.isEmpty;

  /// Writes the draft; calls are serialized so a slow write never races the next.
  Future<void> _flush() => _flushing = _flushing.then((_) async {
        if (!_autosave || !_pending) return;
        if (_draftId == null && _isEmpty) return; // nothing typed yet: don't create a draft
        _pending = false;
        final name = _name.text.trim().isEmpty ? untitled : _name.text.trim();
        try {
          if (_draftId == null) {
            _draftId = await _repo.createDraft(
                name: name, template: _template.text, platform: _platformName, fallbacks: _cleanFallbacks,
                channel: _channel, subject: _subjectOrNull);
          } else {
            await _repo.updateDraft(_draftId!,
                name: name, template: _template.text, channel: _channel, subject: _subjectOrNull);
            await _repo.saveFallbacks(_draftId!, _cleanFallbacks);
          }
          await _repo.saveAudience(_draftId!, CampaignAudience(groupIds: {..._groupIds}, contactIds: {..._contactIds}));
          _version.state++;
          if (mounted) setState(() => _savedAt = DateTime.now());
        } catch (e) {
          debugPrint('Draft autosave failed: $e'); // e.g. deleted elsewhere; the form still has the text
        }
      });

  void _replan() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final seq = ++_planSeq;
      final hasSelection = _groupIds.isNotEmpty || _contactIds.isNotEmpty;
      final plan = (_template.text.trim().isEmpty || !hasSelection)
          ? null
          : await ref.read(composerProvider).plan(
              template: _template.text, groupIds: _groupIds, contactIds: _contactIds, fallbacks: _cleanFallbacks,
              channel: _channel, subject: _subject.text.trim(),
              smsSignature: await ref.read(settingsRepositoryProvider).signature());
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
    _changed();
  }

  String _platform() {
    final caps = ref.read(capabilitiesProvider).valueOrNull;
    if (caps != null) return caps.platform == SmsPlatform.ios ? 'ios' : 'android';
    return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  }

  Future<void> _save() async {
    final plan = _plan;
    if (plan == null || !plan.canSave || _name.text.trim().isEmpty || _needsSubject) return;
    setState(() => _saving = true);
    _autosaveTimer?.cancel();
    await _flushing;
    try {
      final id = await ref.read(composerProvider).save(
          campaignId: _draftId ?? widget.campaignId, name: _name.text, template: _template.text,
          platform: _platformName, plan: plan,
          audience: CampaignAudience(groupIds: {..._groupIds}, contactIds: {..._contactIds}),
          fallbacks: _cleanFallbacks, channel: _channel, subject: _subjectOrNull);
      // It is ready now: stop autosaving so leaving can't turn it back into a draft.
      _autosave = false;
      _pending = false;
      _dirty = false;
      _version.state++;
      if (mounted) context.go('/campaigns/$id');
    } on ProRequiredException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        await showProRequired(context, e.message); // the draft stays saved
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  bool get _needsSubject => _channel.usesEmail && (_plan?.emailCount ?? 0) > 0 && _subject.text.trim().isEmpty;

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this campaign have not been saved. It will stay as it was.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Discard')),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    setState(() => _dirty = false);
    if (mounted) Navigator.of(context).pop();
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
    final canSave = !_saving && plan != null && plan.canSave && _name.text.trim().isNotEmpty && !_needsSubject;
    final email = ref.watch(emailSettingsProvider).valueOrNull;
    final signature = ref.watch(campaignSignatureProvider).valueOrNull;
    final pro = ref.watch(proStatusProvider).valueOrNull?.isPro() ?? false;
    final fallbackKeys = {...?plan?.unresolvedVariables, ..._fallbacks.keys}.toList()..sort();
    final messenger = ScaffoldMessenger.of(context);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _confirmDiscard();
        } else if (_autosave && (_draftId != null || !_isEmpty)) {
          messenger.showSnackBar(const SnackBar(content: Text('Saved as a draft.')));
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(title), actions: [
          if (_autosave && _savedAt != null)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(child: Text('Draft saved')),
            ),
        ]),
        body: FormPage(
          action: FilledButton(
            onPressed: canSave ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Save and review'),
          ),
          children: [
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Campaign name'),
              onChanged: (_) {
                setState(() {});
                _changed();
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<SendChannel>(
              initialValue: _channel,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Send by'),
              items: const [
                DropdownMenuItem(value: SendChannel.sms, child: Text('Text (SMS)')),
                DropdownMenuItem(value: SendChannel.email, child: Text('Email')),
                DropdownMenuItem(value: SendChannel.both, child: Text('Text and email')),
                DropdownMenuItem(value: SendChannel.smsElseEmail, child: Text('Text, or email if no number')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _channel = v);
                _changed();
              },
            ),
            if (_channel.usesEmail && email != null && !email.ready)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => context.push('/settings/email'),
                  icon: const Icon(Icons.warning_amber_rounded),
                  label: const Text('Email isn\'t set up yet: set it up in Settings › Email'),
                ),
              ),
            if (_channel.usesEmail) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _subject,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    labelText: 'Email subject',
                    errorText: _needsSubject ? 'Emails need a subject' : null,
                    helperText: 'Placeholders like {first_name} work here too.'),
                onChanged: (_) {
                  setState(() {});
                  _changed();
                },
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _template,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Message', alignLabelWithHint: true),
              onChanged: (_) {
                setState(() {}); // live text counter
                _changed();
              },
            ),
            MessageCounter(
              template: _template.text,
              plan: _plan,
              signature: _channel.usesSms ? signature : null,
              onUsePlain: (plain) {
                final cursor = _template.selection;
                _template.value = TextEditingValue(
                  text: plain,
                  selection: TextSelection.collapsed(offset: cursor.isValid ? cursor.end.clamp(0, plain.length) : plain.length),
                );
                setState(() {});
                _changed();
              },
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
                      _changed();
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
                  _changed();
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
                    decoration: InputDecoration(labelText: '{$k}'),
                    onChanged: (v) {
                      _fallbacks[k] = v;
                      _changed();
                    },
                  ),
                ),
            ],
            const SizedBox(height: 24),
            if (plan != null) PlanSummary(plan, channel: _channel, signature: signature, pro: pro),
          ],
        ),
      ),
    );
  }
}

/// What will actually be sent, derived from the plan. Shown before saving.
class PlanSummary extends StatelessWidget {
  const PlanSummary(this.plan, {super.key, this.channel = SendChannel.sms, this.signature, this.pro = false});
  final SnapshotPlan plan;
  final SendChannel channel;
  /// Added to every text and email when sent (null = none).
  final String? signature;
  final bool pro;

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
          Text(
              plan.emailCount == 0
                  ? '${plan.recipients.length} ${plan.recipients.length == 1 ? 'recipient' : 'recipients'}'
                  : [
                      if (plan.smsCount > 0) '${plan.smsCount} ${plan.smsCount == 1 ? 'text' : 'texts'}',
                      '${plan.emailCount} ${plan.emailCount == 1 ? 'email' : 'emails'}',
                    ].join(' · '),
              style: Theme.of(context).textTheme.titleLarge),
          if (est.messages > 0)
            line('About ${est.totalSegments} SMS ${est.totalSegments == 1 ? 'segment' : 'segments'} in total '
                '(up to ${est.maxSegments} per message). Carrier charges apply per segment.'),
          if (est.unicodeMessages > 0)
            line('${est.unicodeMessages} messages contain special characters, which shortens each segment.'),
          if (e.excludedSuppressed.isNotEmpty) line('${e.excludedSuppressed.length} excluded: on the suppression list.'),
          if (e.excludedOptedOut.isNotEmpty) line('${e.excludedOptedOut.length} excluded: opted out.'),
          if (e.excludedInvalid.isNotEmpty)
            line('${e.excludedInvalid.length} excluded: ${switch (channel) {
              SendChannel.sms => 'invalid phone number',
              SendChannel.email => 'no valid email address',
              _ => 'no valid number or email',
            }}.'),
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
              child: Text(withSignature(plan.recipients.first.renderedMessage, signature)),
            ),
            if (signature != null && !pro)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: () => context.push('/settings/pro'),
                  child: const Text('Change or remove the signature with Pro'),
                ),
              ),
            if (plan.recipients.where((r) => r.channel == MessageChannel.email).firstOrNull case final m?) ...[
              const SizedBox(height: 12),
              Text('Email to ${m.email}', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m.subject ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(m.renderedMessage),
                  if (signature != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(signature!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                ]),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}
