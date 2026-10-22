import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../domain/models/schedule.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../campaigns/campaign_labels.dart';

/// Keeps schedules moving while the app is open: at start, every 30 seconds,
/// on returning to the app, and after any data change.
/// - Android: keeps the service's wake-up alarm on the next run, and starts the
///   service if a run is due now (e.g. exact alarms are not allowed). The
///   service does all the sending, so the app never sends at the same time.
/// - Elsewhere (iOS): prepares due runs here; the user taps Send.
class ScheduleTicker extends ConsumerStatefulWidget {
  const ScheduleTicker({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ScheduleTicker> createState() => _ScheduleTickerState();
}

class _ScheduleTickerState extends ConsumerState<ScheduleTicker> with WidgetsBindingObserver {
  Timer? _timer;
  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    // Schedules edited, paused or removed: move the wake-up alarm promptly.
    ref.listenManual(dataVersionProvider, (_, __) {
      _wakeDebounce?.cancel();
      _wakeDebounce = Timer(const Duration(seconds: 1), _syncWake);
    });
  }

  Timer? _wakeDebounce;

  Future<bool> _syncWake() async {
    final bg = ref.read(backgroundSendServiceProvider);
    if (bg == null) return false;
    try {
      return await bg.scheduleWake(await ref.read(scheduleRepositoryProvider).nextWake());
    } catch (e) {
      debugPrint('Could not set the schedule wake-up: $e');
      return false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _wakeDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick();
  }

  void _say(String m) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final bg = ref.read(backgroundSendServiceProvider);
      if (bg != null) {
        await _syncWake();
        if ((await ref.read(scheduleRepositoryProvider).due(DateTime.now())).isNotEmpty &&
            !(await bg.status()).serviceRunning) {
          await bg.checkNow();
        }
        return;
      }
      SmsCapabilities? caps;
      try {
        caps = await ref.read(capabilitiesProvider.future);
      } catch (_) {/* treated as "can't send automatically" */}
      final ios = caps?.platform == SmsPlatform.ios;
      final canAuto = caps != null && caps.platform == SmsPlatform.android && caps.canSendDirectly;
      final results = await ref
          .read(scheduleRunnerProvider)
          .runDue(DateTime.now(), platform: ios ? 'ios' : 'android', canAutoSend: canAuto);
      if (results.isEmpty) return;
      ref.read(dataVersionProvider.notifier).state++;
      for (final r in results) {
        final name = r.campaignName ?? 'A scheduled campaign';
        _say('$name: ${scheduleOutcomeLabel(r.outcome)}.');
        if (r.outcome == ScheduleOutcome.started && r.campaignId != null) {
          unawaited(ref.read(sendOrchestratorProvider).runAndroid(r.campaignId!).then(
                (_) => ref.read(dataVersionProvider.notifier).state++,
                onError: (Object e) => _say('$name could not be sent: $e'),
              ));
        }
      }
    } catch (e) {
      debugPrint('Schedule check failed: $e');
    } finally {
      _ticking = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
