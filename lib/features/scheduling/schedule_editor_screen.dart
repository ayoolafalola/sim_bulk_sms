import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/schedule.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';
import '../../domain/services/schedule_calculator.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../../app/sending_providers.dart';
import '../../app/app_info.dart';
import '../common/page_layout.dart';
import '../../domain/models/pro.dart';
import '../pro/pro_screen.dart';
import '../setup/setup_status.dart';

/// Set when a campaign sends: once at a date/time, or every week on chosen days.
/// Saving is the approval: scheduled runs don't ask again.
class ScheduleEditorScreen extends ConsumerStatefulWidget {
  const ScheduleEditorScreen({super.key, required this.campaignId, this.now});
  final int campaignId;
  /// Clock override for tests.
  final DateTime Function()? now;

  @override
  ConsumerState<ScheduleEditorScreen> createState() => _ScheduleEditorScreenState();
}

class _ScheduleEditorScreenState extends ConsumerState<ScheduleEditorScreen> {
  static const _dayLetters = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  DateTime _now() => (widget.now ?? DateTime.now)();

  Campaign? _campaign;
  bool _loading = true, _saving = false;
  ScheduleKind _kind = ScheduleKind.weekly;
  late DateTime _onceAt;
  int _weekdays = 0;
  int _minuteOfDay = 8 * 60;
  DateTime? _endsOn;
  CampaignEstimate? _perRun;
  String? _problem; // why this campaign can't be scheduled this way

  @override
  void initState() {
    super.initState();
    final t = _now().add(const Duration(days: 1));
    _onceAt = DateTime(t.year, t.month, t.day, 8);
    _load();
  }

  Future<void> _load() async {
    final c = await ref.read(campaignRepositoryProvider).get(widget.campaignId);
    final existing = await ref.read(scheduleRepositoryProvider).forCampaign(widget.campaignId);
    if (existing != null) {
      _kind = existing.kind;
      if (existing.runAt != null) _onceAt = existing.runAt!;
      _weekdays = existing.weekdays;
      _minuteOfDay = existing.minuteOfDay ?? _minuteOfDay;
      _endsOn = existing.endsOn;
    } else if (c != null && c.status != CampaignStatus.ready) {
      _kind = ScheduleKind.weekly; // one-time needs a ready campaign
    }
    if (_weekdays == 0) _weekdays = CampaignSchedule.bit(DateTime.sunday);
    _campaign = c;
    await _estimate();
    if (mounted) setState(() => _loading = false);
  }

  /// Per-run size: a one-time run sends the saved snapshot; a weekly run
  /// re-reads the groups each time, so estimate from today's members.
  Future<void> _estimate() async {
    final c = _campaign;
    if (c == null) return;
    _problem = null;
    _perRun = null;
    if (_kind == ScheduleKind.once) {
      if (c.status != CampaignStatus.ready) {
        _problem = 'Only a campaign that is ready to send can be scheduled once. Use "Repeat weekly", '
            'or "Send again" to make a new ready copy.';
        return;
      }
      final rs = await ref.read(campaignRecipientsProvider(c.id).future);
      _perRun = estimateCampaign([for (final r in rs) if (r.status == RecipientStatus.pending) r.renderedMessage]);
    } else {
      final a = await ref.read(campaignRepositoryProvider).audience(c.id);
      if (a.isEmpty) {
        _problem = 'This campaign has no saved groups or contacts. Edit it and pick recipients first.';
        return;
      }
      final p = await ref.read(composerProvider).planForCampaign(c);
      if (p.blocked.isNotEmpty) {
        _problem = 'Some recipients have no value for ${p.unresolvedVariables.map((v) => '{$v}').join(', ')}. '
            'Edit the campaign and add a fallback.';
        return;
      }
      _perRun = p.estimate;
    }
  }

  ScheduleSpec get _spec => _kind == ScheduleKind.once
      ? ScheduleSpec.once(_onceAt)
      : ScheduleSpec.weekly(weekdays: _weekdays, minuteOfDay: _minuteOfDay, endsOn: _endsOn);

  Future<void> _setKind(ScheduleKind k) async {
    setState(() => _kind = k);
    await _estimate();
    if (mounted) setState(() {});
  }

  Future<void> _pickOnceDate() async {
    final d = await showDatePicker(
        context: context, initialDate: _onceAt, firstDate: DateTime(_now().year, _now().month, _now().day),
        lastDate: _now().add(const Duration(days: 366)));
    if (d != null) setState(() => _onceAt = DateTime(d.year, d.month, d.day, _onceAt.hour, _onceAt.minute));
  }

  Future<void> _pickTime({required bool once}) async {
    final initial = once
        ? TimeOfDay(hour: _onceAt.hour, minute: _onceAt.minute)
        : TimeOfDay(hour: _minuteOfDay ~/ 60, minute: _minuteOfDay % 60);
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t == null) return;
    setState(() {
      if (once) {
        _onceAt = DateTime(_onceAt.year, _onceAt.month, _onceAt.day, t.hour, t.minute);
      } else {
        _minuteOfDay = t.hour * 60 + t.minute;
      }
    });
  }

  Future<void> _pickEnd() async {
    final d = await showDatePicker(
        context: context, initialDate: _endsOn ?? _now().add(const Duration(days: 30)),
        firstDate: DateTime(_now().year, _now().month, _now().day), lastDate: _now().add(const Duration(days: 3650)));
    if (d != null) setState(() => _endsOn = d);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // iPhone / iPad: runs are announced by a reminder, which needs notification permission.
    await ref.read(scheduleRemindersProvider)?.requestPermission();
    final pro = await ref.read(settingsRepositoryProvider).loadPro();
    try {
      await ref.read(scheduleRepositoryProvider).save(widget.campaignId, _spec, now: _now(),
          maxSchedules: pro.has(ProFeature.unlimitedSchedules) ? null : FreeLimits.schedules);
    } on ProRequiredException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        await showProRequired(context, e.message);
      }
      return;
    }
    ref.read(dataVersionProvider.notifier).state++;
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(appBar: AppBar(title: const Text('Schedule')), body: const Center(child: CircularProgressIndicator()));
    }
    final c = _campaign;
    if (c == null) {
      return Scaffold(appBar: AppBar(title: const Text('Schedule')), body: const Center(child: Text('This campaign no longer exists.')));
    }
    final next = nextOccurrence(_spec, _now());
    final caps = ref.watch(capabilitiesProvider).valueOrNull;
    final ios = caps?.platform == SmsPlatform.ios;
    final canSave = !_saving && _problem == null && next != null && _perRun != null && _perRun!.messages > 0;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text('Schedule · ${c.name}')),
      body: FormPage(
          action: FilledButton(onPressed: canSave ? _save : null, child: Text(_saving ? 'Saving…' : 'Save schedule')),
          children: [
        SegmentedButton<ScheduleKind>(
          segments: const [
            ButtonSegment(value: ScheduleKind.once, label: Text('Once'), icon: Icon(Icons.event)),
            ButtonSegment(value: ScheduleKind.weekly, label: Text('Repeat weekly'), icon: Icon(Icons.repeat)),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => _setKind(s.first),
        ),
        const SizedBox(height: 16),
        if (_kind == ScheduleKind.once) ...[
          ListTile(
            leading: const Icon(Icons.calendar_today),
            title: const Text('Date'),
            subtitle: Text(formatDateTime(_onceAt).split(',').first),
            onTap: _pickOnceDate,
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Time'),
            subtitle: Text(formatTime(_onceAt.hour * 60 + _onceAt.minute)),
            onTap: () => _pickTime(once: true),
          ),
        ] else ...[
          Text('On', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (var w = 1; w <= 7; w++)
              FilterChip(
                label: Text(_dayLetters[w - 1]),
                selected: _weekdays & CampaignSchedule.bit(w) != 0,
                onSelected: (on) => setState(() => _weekdays ^= CampaignSchedule.bit(w)),
              ),
          ]),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule),
            title: const Text('Time'),
            subtitle: Text(formatTime(_minuteOfDay)),
            onTap: () => _pickTime(once: false),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_busy),
            title: const Text('Ends'),
            subtitle: Text(_endsOn == null ? 'Never' : formatDateTime(_endsOn!).split(',').first),
            onTap: _pickEnd,
            trailing: _endsOn == null
                ? null
                : IconButton(tooltip: 'No end date', icon: const Icon(Icons.clear), onPressed: () => setState(() => _endsOn = null)),
          ),
        ],
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(describeSchedule(_spec), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(next == null
                  ? (_kind == ScheduleKind.weekly && _weekdays == 0 ? 'Pick at least one day.' : 'That time has already passed.')
                  : 'Next run: ${formatDateTime(next)}',
                  style: next == null ? TextStyle(color: scheme.error) : null),
              if (_problem != null) ...[
                const SizedBox(height: 8),
                Text(_problem!, style: TextStyle(color: scheme.error)),
              ] else if (_perRun != null) ...[
                const SizedBox(height: 8),
                Text(_perRun!.messages == 0
                    ? 'No one would receive this right now.'
                    : 'Each run sends about ${_perRun!.messages} messages (${_perRun!.totalSegments} SMS segments). '
                        'Carrier charges apply to every run.'),
                if (_kind == ScheduleKind.weekly)
                  const Text('Each run goes to whoever is in the groups at that time, minus opted-out and suppressed numbers.'),
                if (ref.watch(sendSettingsProvider).valueOrNull case final cfg?
                    when cfg.dailyLimit > 0 && _perRun!.messages > cfg.dailyLimit) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Each run is more than your daily limit of ${cfg.dailyLimit} messages, so it will pause and '
                    'continue the next day (about ${(_perRun!.messages / cfg.dailyLimit).ceil()} days per run).',
                    style: TextStyle(color: scheme.tertiary),
                  ),
                ],
              ],
            ]),
          ),
        ),
        if (ref.watch(setupStatusProvider).valueOrNull case final setup? when !ios)
          for (final i in setup.missingRequired)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${setupInfoFor(i).title} is off: ${setupInfoFor(i).ifMissing}', style: TextStyle(color: scheme.error)),
            ),
        const SizedBox(height: 8),
        Card(
          color: scheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(ios
                ? 'Texts can\'t be sent automatically on this device. When a run is due you get a reminder: open it and tap '
                    'Send for each text. Emails in the run go out by themselves.'
                : isStoreBuild
                    ? 'When a run is due you get a notification. Open the app and send each message through your '
                        'Messages app. A run more than 2 hours late is skipped.'
                    : 'Saving this schedule approves the sends: they will not ask again. '
                    'Runs send in the background, even with the app closed, once background sending is set up. '
                    'A run more than 2 hours late (for example, phone off) is skipped.'),
          ),
        ),
        if (!ios && caps != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => context.push('/settings/setup'),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('App setup'),
            ),
          ),
      ]),
    );
  }
}
