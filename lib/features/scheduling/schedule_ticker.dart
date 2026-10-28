import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/app_info.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../domain/models/schedule.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../campaigns/campaign_labels.dart';
import '../../app/router.dart';
import '../../platform/reminders/schedule_reminders.dart';
import 'next_wake.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tick();
      _syncReminders();
    });
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    // Schedules edited, paused or removed: move the wake-up alarm promptly.
    ref.listenManual(dataVersionProvider, (_, __) {
      _wakeDebounce?.cancel();
      _wakeDebounce = Timer(const Duration(seconds: 1), () {
        _syncWake();
        _syncReminders();
      });
    });
  }

  Timer? _wakeDebounce;

  Future<bool> _syncWake() async {
    final bg = ref.read(backgroundSendServiceProvider);
    if (bg == null) return false;
    try {
      return await bg.scheduleWake(await nextWakeUp(
          ref.read(scheduleRepositoryProvider), ref.read(campaignRepositoryProvider),
          birthdays: ref.read(birthdayRunnerProvider)));
    } catch (e) {
      debugPrint('Could not set the schedule wake-up: $e');
      return false;
    }
  }

  /// iPhone / iPad: keep a local reminder at each upcoming scheduled run.
  Future<void> _syncReminders() async {
    final reminders = ref.read(scheduleRemindersProvider);
    if (reminders == null) return;
    try {
      final now = DateTime.now();
      final birthdays = ref.read(birthdayRunnerProvider);
      final all = [
        ...remindersFor(await ref.read(scheduleRepositoryProvider).list(), now),
        // Birthday wishes (Pro, when on): a reminder on each day with birthdays.
        if (await birthdays.nextRunAt(now) != null)
          ...birthdayReminders(await birthdays.upcoming(now), await ref.read(settingsRepositoryProvider).loadBirthdays(), now),
      ]..sort((a, b) => a.at.compareTo(b.at));
      await reminders.set(all.take(60).toList());
    } catch (e) {
      debugPrint('Could not set schedule reminders: $e');
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
    if (state == AppLifecycleState.resumed) {
      // Permissions may have changed in system settings: re-check (drives the setup warnings).
      ref.read(backgroundStatusVersionProvider.notifier).state++;
      _tick();
    }
  }

  /// Birthday wishes in the app (iPhone / iPad, or Android without the background service): emails go
  /// now; on iPhone the run then opens, ready for a tap per text.
  Future<void> _runBirthdays({required bool ios, required bool canAuto}) async {
    final b = await ref.read(birthdayRunnerProvider).runDue(DateTime.now(), platform: ios ? 'ios' : 'android');
    final id = b.campaignId;
    if (id == null) return;
    ref.read(dataVersionProvider.notifier).state++;
    _say('Birthday wishes: ${b.people} ${b.people == 1 ? 'birthday' : 'birthdays'} today.');
    final orch = ref.read(sendOrchestratorProvider);
    try {
      if (canAuto) {
        await orch.runAndroid(id);
      } else {
        await orch.runEmails(id);
      }
    } catch (e) {
      debugPrint('Birthday wishes not sent automatically: $e');
    }
    ref.read(dataVersionProvider.notifier).state++;
    if (ios && b.texts > 0) appRouter.go('/campaigns/$id');
  }

  void _say(String m) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final bg = ref.read(backgroundSendServiceProvider);
      if (isStoreBuild) await _syncWake(); // store build: the alarm only posts a "due" reminder
      if (bg != null && !isStoreBuild) {
        await _syncWake();
        final now = DateTime.now();
        final due = (await ref.read(scheduleRepositoryProvider).due(now)).isNotEmpty ||
            (await ref.read(campaignRepositoryProvider).dueResumes(now)).isNotEmpty ||
            await ref.read(birthdayRunnerProvider).isDue(now);
        if (due && !(await bg.status()).serviceRunning) {
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
      await _runBirthdays(ios: ios, canAuto: canAuto);
      final results = await ref
          .read(scheduleRunnerProvider)
          .runDue(DateTime.now(), platform: ios ? 'ios' : 'android', canAutoSend: canAuto);
      if (results.isEmpty) return;
      ref.read(dataVersionProvider.notifier).state++;
      // Opened from a reminder (or the app was open): go straight to the run that needs you.
      final ready = results.where((r) => r.outcome == ScheduleOutcome.needsAttention && r.campaignId != null).firstOrNull;
      if (ios && ready != null) appRouter.go('/campaigns/${ready.campaignId}');
      for (final r in results) {
        final name = r.campaignName ?? 'A scheduled campaign';
        _say('$name: ${scheduleOutcomeLabel(r.outcome)}.');
        if (r.outcome == ScheduleOutcome.started && r.campaignId != null) {
          unawaited(ref.read(sendOrchestratorProvider).runAndroid(r.campaignId!).then(
                (_) => ref.read(dataVersionProvider.notifier).state++,
                onError: (Object e) => _say('$name could not be sent: $e'),
              ));
        } else if (r.outcome == ScheduleOutcome.needsAttention && r.campaignId != null) {
          // Texts wait for you; its emails (if any) go now.
          unawaited(ref.read(sendOrchestratorProvider).runEmails(r.campaignId!).then(
                (_) => ref.read(dataVersionProvider.notifier).state++,
                onError: (Object _) {},
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
