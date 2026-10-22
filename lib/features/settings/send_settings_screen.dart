import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/settings_providers.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/send_settings.dart';
import '../common/page_layout.dart';

/// "NG (+234)" for every country the phone-number library knows, sorted by code.
final List<({String code, String label})> countryOptions = [
  for (final c in IsoCode.values.toList()..sort((a, b) => a.name.compareTo(b.name)))
    (code: c.name, label: '${c.name} (+${PhoneNumber(isoCode: c, nsn: '').countryCode})'),
];

/// Delay between messages, hourly/daily limits and default country. Changes
/// save immediately and apply to the next message (also in the background).
class SendSettingsScreen extends ConsumerStatefulWidget {
  const SendSettingsScreen({super.key});

  @override
  ConsumerState<SendSettingsScreen> createState() => _SendSettingsScreenState();
}

class _SendSettingsScreenState extends ConsumerState<SendSettingsScreen> {
  SendSettings? _s;
  final _hourly = TextEditingController();
  final _daily = TextEditingController();
  Timer? _saveDebounce;
  ({int hour, int day})? _usage;

  late final SettingsRepository _repo;
  bool _unsaved = false;

  @override
  void initState() {
    super.initState();
    _repo = ref.read(settingsRepositoryProvider);
    _load();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    if (_unsaved && _s != null) _repo.save(_s!); // flush the last change
    _hourly.dispose();
    _daily.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await _repo.load();
    final now = DateTime.now();
    final sent = await ref.read(attemptRepositoryProvider).sendTimesSince(now.subtract(const Duration(hours: 24)));
    if (!mounted) return;
    setState(() {
      _s = s;
      _hourly.text = '${s.hourlyLimit > 0 ? s.hourlyLimit : SendSettings.defaultHourlyLimit}';
      _daily.text = '${s.dailyLimit > 0 ? s.dailyLimit : SendSettings.defaultDailyLimit}';
      _usage = (hour: sent.where((t) => now.difference(t) < const Duration(hours: 1)).length, day: sent.length);
    });
  }

  void _update(SendSettings s) {
    setState(() => _s = s);
    _unsaved = true;
    ref.read(defaultRegionProvider.notifier).state = s.defaultRegion;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () async {
      _unsaved = false;
      await _repo.save(s);
      if (mounted) ref.read(dataVersionProvider.notifier).state++;
    });
  }

  int _parse(TextEditingController c, int fallback) {
    final v = int.tryParse(c.text.trim());
    return v == null || v < 1 ? fallback : v;
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) {
      return Scaffold(appBar: AppBar(title: const Text('Send settings')), body: const Center(child: CircularProgressIndicator()));
    }
    final small = Theme.of(context).textTheme.bodySmall;
    Widget limit({
      required String title, required int value, required TextEditingController ctrl, required int fallback,
      required SendSettings Function(int) set,
    }) =>
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(title),
                value: value > 0,
                onChanged: (on) => _update(set(on ? _parse(ctrl, fallback) : 0)),
              ),
              if (value > 0)
                TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Messages', isDense: true),
                  onChanged: (_) => _update(set(_parse(ctrl, fallback))),
                ),
            ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Send settings')),
      body: ListView(padding: pagePadding(context, extra: 24), children: [
        Text('Sending too fast or too much can get a SIM blocked by the carrier. '
            'These settings apply to the next message, including scheduled and background sends.', style: small),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Delay between messages: ${s.delaySeconds} s', style: Theme.of(context).textTheme.titleSmall),
              Slider(
                value: s.delaySeconds.toDouble(),
                min: SendSettings.minDelay.toDouble(),
                max: SendSettings.maxDelay.toDouble(),
                divisions: SendSettings.maxDelay - SendSettings.minDelay,
                label: '${s.delaySeconds} s',
                onChanged: (v) => _update(s.copyWith(delaySeconds: v.round())),
              ),
            ]),
          ),
        ),
        limit(title: 'Hourly limit', value: s.hourlyLimit, ctrl: _hourly, fallback: SendSettings.defaultHourlyLimit,
            set: (v) => s.copyWith(hourlyLimit: v)),
        limit(title: 'Daily limit', value: s.dailyLimit, ctrl: _daily, fallback: SendSettings.defaultDailyLimit,
            set: (v) => s.copyWith(dailyLimit: v)),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Text(
            'Limits count messages sent from this phone in the last 60 minutes and the last 24 hours. '
            'When one is reached, sending pauses and resumes automatically.'
            '${_usage == null ? '' : '\nSent in the last hour: ${_usage!.hour}'
                '${s.hourlyLimit > 0 ? ' / ${s.hourlyLimit}' : ''} · last 24 h: ${_usage!.day}'
                '${s.dailyLimit > 0 ? ' / ${s.dailyLimit}' : ''}'}',
            style: small,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Default country', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('Used for numbers saved or imported without a +country code.', style: small),
              const SizedBox(height: 8),
              DropdownMenu<String>(
                initialSelection: s.defaultRegion,
                enableFilter: true,
                requestFocusOnTap: true,
                expandedInsets: EdgeInsets.zero,
                menuHeight: 320,
                dropdownMenuEntries: [
                  for (final c in countryOptions) DropdownMenuEntry(value: c.code, label: c.label),
                ],
                onSelected: (v) {
                  if (v != null) _update(s.copyWith(defaultRegion: v));
                },
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
