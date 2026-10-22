import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/sending_providers.dart';
import '../../platform/background/background_send_service.dart';

/// Checklist of the phone settings background sending needs, each with a
/// button that opens the right place. Re-checks when you come back to the app.
class BackgroundSetupScreen extends ConsumerStatefulWidget {
  const BackgroundSetupScreen({super.key});

  @override
  ConsumerState<BackgroundSetupScreen> createState() => _BackgroundSetupScreenState();
}

class _BackgroundSetupScreenState extends ConsumerState<BackgroundSetupScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _recheck();
  }

  void _recheck() => ref.read(backgroundStatusVersionProvider.notifier).state++;

  @override
  Widget build(BuildContext context) {
    final bg = ref.watch(backgroundSendServiceProvider);
    final status = ref.watch(backgroundStatusProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Background sending'), actions: [
        IconButton(tooltip: 'Check again', icon: const Icon(Icons.refresh), onPressed: _recheck),
      ]),
      body: bg == null
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text('iPhone cannot send SMS in the background. When a scheduled run is due, '
                  'open the app and tap Send for each message.'),
            )
          : status.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not read the phone settings: $e')),
              data: (s) => s == null ? const SizedBox.shrink() : _Checklist(bg: bg, s: s, recheck: _recheck),
            ),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist({required this.bg, required this.s, required this.recheck});
  final BackgroundSendService bg;
  final BackgroundStatus s;
  final VoidCallback recheck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        color: s.ready ? scheme.primaryContainer : scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(s.ready ? Icons.check_circle : Icons.warning_amber),
            const SizedBox(width: 12),
            Expanded(
              child: Text(s.ready
                  ? 'Ready. Scheduled runs send on time, even with the app closed, and sends continue if you leave the app.'
                  : s.exactAlarms
                      ? 'Almost ready. Fix the items below so the phone does not block or hide background sending.'
                      : 'Not ready. Without "Alarms & reminders", scheduled runs only start while the app is open.'),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      _Item(
        ok: s.notifications,
        title: 'Notifications',
        why: 'Shows progress while sending and tells you when a scheduled run finishes or has a problem.',
        action: 'Allow',
        onFix: () async {
          if (!await bg.requestNotifications()) await bg.openNotificationSettings();
          recheck();
        },
      ),
      _Item(
        ok: s.exactAlarms,
        title: 'Alarms & reminders',
        why: 'Lets the app wake up at the exact scheduled time, even when it is closed.',
        action: 'Open settings',
        onFix: bg.openExactAlarmSettings,
      ),
      _Item(
        ok: s.batteryUnrestricted,
        title: 'Battery: Unrestricted',
        why: 'Stops Android from delaying or blocking the wake-up to save battery.\n'
            'On Samsung also: Settings › Battery › Background usage limits › Never sleeping apps › add SIM Bulk SMS.',
        action: 'Open settings',
        onFix: bg.openBatterySettings,
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: bg.openAppSettings,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Open app settings'),
        ),
      ),
    ]);
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.ok, required this.title, required this.why, required this.action, required this.onFix});
  final bool ok;
  final String title, why, action;
  final Future<void> Function() onFix;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked,
                color: ok ? Theme.of(context).colorScheme.primary : null),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(why),
                if (!ok) ...[
                  const SizedBox(height: 8),
                  FilledButton.tonal(onPressed: onFix, child: Text(action)),
                ],
              ]),
            ),
          ]),
        ),
      );
}
