import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/birthday_settings.dart';
import '../../domain/models/channels.dart';
import '../../domain/models/pro.dart';
import '../../core/templates/template_renderer.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../pro/pro_screen.dart';
import 'birthday_runner.dart';

/// Birthdays in the next 30 days, from the wishes' audience.
final upcomingBirthdaysProvider = FutureProvider<List<UpcomingBirthday>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(birthdayRunnerProvider).upcoming(DateTime.now());
});

/// How many contacts have a birthday saved, out of all.
final birthdayCoverageProvider = FutureProvider<({int known, int total})>((ref) async {
  ref.watch(dataVersionProvider);
  final all = await ref.watch(contactRepositoryProvider).search();
  return (known: all.where((c) => c.birthday != null).length, total: all.length);
});

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _when(DateTime d, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final days = d.difference(today).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

String _time(int minute) => '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

/// Campaigns › Birthday wishes (Comeriver Pro): an automatic message on each person's birthday.
class BirthdayWishesScreen extends ConsumerStatefulWidget {
  const BirthdayWishesScreen({super.key});

  @override
  ConsumerState<BirthdayWishesScreen> createState() => _BirthdayWishesScreenState();
}

class _BirthdayWishesScreenState extends ConsumerState<BirthdayWishesScreen> {
  BirthdaySettings? _s;
  final _template = TextEditingController(), _subject = TextEditingController();
  Timer? _debounce;
  late final SettingsRepository _repo;
  late final StateController<int> _version;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(settingsRepositoryProvider);
    _version = ref.read(dataVersionProvider.notifier);
    _repo.loadBirthdays().then((s) {
      if (!mounted) return;
      _template.text = s.template;
      _subject.text = s.subject;
      setState(() => _s = s);
    });
  }

  @override
  void dispose() {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      _write(); // keep the last edit
    }
    _template.dispose();
    _subject.dispose();
    super.dispose();
  }

  BirthdaySettings get _current => _s!.copyWith(template: _template.text, subject: _subject.text);

  /// Writes the form, keeping the run date the database has (the background service may have run today).
  Future<void> _write() async {
    final form = _current;
    final saved = await _repo.loadBirthdays();
    await _repo.saveBirthdays(BirthdaySettings(
      enabled: form.enabled, channel: form.channel, template: form.template, subject: form.subject,
      minuteOfDay: form.minuteOfDay, groupIds: form.groupIds, lastRunDate: saved.lastRunDate,
    ));
  }

  /// Saves now (switches, pickers) or shortly after typing stops.
  void _save({bool soon = false}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: soon ? 600 : 0), () async {
      await _write();
      _version.state++;
    });
  }

  void _insert(String v) {
    final sel = _template.selection;
    final text = _template.text;
    final at = sel.isValid ? sel.start : text.length, end = sel.isValid ? sel.end : text.length;
    _template.value = TextEditingValue(
        text: text.replaceRange(at, end, '{$v}'), selection: TextSelection.collapsed(offset: at + v.length + 2));
    setState(() {});
    _save(soon: true);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) {
      return Scaffold(appBar: AppBar(title: const Text('Birthday wishes')), body: const Center(child: CircularProgressIndicator()));
    }
    final pro = ref.watch(proStatusProvider).valueOrNull?.has(ProFeature.birthdayWishes) ?? false;
    final groups = ref.watch(groupsProvider).valueOrNull ?? const [];
    final upcoming = ref.watch(upcomingBirthdaysProvider).valueOrNull ?? const <UpcomingBirthday>[];
    final coverage = ref.watch(birthdayCoverageProvider).valueOrNull;
    final signature = ref.watch(campaignSignatureProvider).valueOrNull;
    final c = AppColors.of(context);
    final now = DateTime.now();
    final sample = TemplateRenderer.render(_template.text, name: 'Ada Okafor', phone: '', fallbacks: const {
      'company': 'Comeriver', 'email': 'ada@example.com', 'birthday': '17 May',
    }).text;

    return Scaffold(
      appBar: AppBar(title: const Text('Birthday wishes')),
      body: ListView(padding: pagePadding(context, extra: 24), children: [
        if (!pro)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: c.infoBg,
            child: ListTile(
              leading: Icon(Icons.workspace_premium, color: c.infoFg),
              title: Text('Part of Comeriver Pro', style: TextStyle(color: c.infoFg, fontWeight: FontWeight.w700)),
              subtitle: Text('Set it up now; it starts sending once Pro is on.', style: TextStyle(color: c.infoFg)),
              trailing: TextButton(onPressed: () => showProRequired(context, _proMessage), child: const Text('See Pro')),
            ),
          ),
        Card(
          margin: EdgeInsets.zero,
          child: SwitchListTile(
            secondary: const Icon(Icons.cake_outlined),
            title: const Text('Send birthday wishes'),
            subtitle: Text(s.enabled
                ? 'Every day at ${_time(s.minuteOfDay)}, to whoever has a birthday.'
                : 'An automatic message on each person\'s birthday.'),
            value: s.enabled && pro,
            onChanged: (v) {
              if (v && !pro) {
                showProRequired(context, _proMessage);
                return;
              }
              setState(() => _s = _current.copyWith(enabled: v));
              _save();
            },
          ),
        ),
        const SectionLabel('Message'),
        DropdownButtonFormField<SendChannel>(
          initialValue: s.channel,
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
            setState(() => _s = _current.copyWith(channel: v));
            _save();
          },
        ),
        if (s.channel.usesEmail) ...[
          const SizedBox(height: 12),
          TextField(controller: _subject, decoration: const InputDecoration(labelText: 'Email subject'),
              onChanged: (_) => _save(soon: true)),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _template,
          minLines: 2,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Message', alignLabelWithHint: true),
          onChanged: (_) {
            setState(() {});
            _save(soon: true);
          },
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final v in const ['first_name', 'name', 'company']) ActionChip(label: Text('{$v}'), onPressed: () => _insert(v)),
        ]),
        if (sample != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: c.neutralBg, borderRadius: BorderRadius.circular(12)),
            child: Text(signature == null ? sample : '$sample\n$signature'),
          ),
        ],
        const SectionLabel('When and to whom'),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Send at'),
            trailing: Text(_time(s.minuteOfDay), style: const TextStyle(fontWeight: FontWeight.w700)),
            onTap: () async {
              final t = await showTimePicker(
                  context: context, initialTime: TimeOfDay(hour: s.minuteOfDay ~/ 60, minute: s.minuteOfDay % 60));
              if (t == null) return;
              setState(() => _s = _current.copyWith(minuteOfDay: t.hour * 60 + t.minute));
              _save();
            },
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('Everyone')),
            ButtonSegment(value: true, label: Text('Chosen groups')),
          ],
          selected: {s.groupIds.isNotEmpty},
          onSelectionChanged: (v) {
            if (v.first && groups.isEmpty) return;
            setState(() => _s = _current.copyWith(groupIds: v.first ? {groups.first.id} : <int>{}));
            _save();
          },
        ),
        if (s.groupIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final g in groups)
              FilterChip(
                label: Text(g.name),
                selected: s.groupIds.contains(g.id),
                onSelected: (on) {
                  final ids = {...s.groupIds};
                  on ? ids.add(g.id) : ids.remove(g.id);
                  if (ids.isEmpty) return; // keep at least one; "Everyone" covers the rest
                  setState(() => _s = _current.copyWith(groupIds: ids));
                  _save();
                },
              ),
          ]),
        ],
        const SizedBox(height: 8),
        Text('Opted-out people are left out. Nobody gets more than one birthday message a year.',
            style: TextStyle(color: c.muted, fontSize: 13)),
        SectionLabel('Next 30 days', trailing: coverage == null ? null
            : Text('${coverage.known} of ${coverage.total} have a birthday', style: TextStyle(color: c.muted, fontSize: 12))),
        if (upcoming.isEmpty)
          Text('No birthdays coming up. Add birthdays on the contact screen, or import them from a file.',
              style: TextStyle(color: c.muted))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final u in upcoming.take(30))
                ListTile(
                  leading: InitialsAvatar(u.contact.name, size: 38),
                  title: Text(u.contact.name),
                  subtitle: u.turns == null ? null : Text('Turns ${u.turns}'),
                  trailing: Text(_when(u.on, now),
                      style: TextStyle(fontWeight: FontWeight.w700, color: u.on.day == now.day && u.on.month == now.month
                          ? Theme.of(context).colorScheme.primary : null)),
                ),
            ]),
          ),
      ]),
    );
  }

  static const _proMessage = 'Birthday wishes is part of Comeriver Pro: an automatic message to each of your '
      'contacts on their birthday.';
}
