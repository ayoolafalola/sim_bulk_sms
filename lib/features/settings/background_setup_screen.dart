import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/sending_providers.dart';
import '../common/page_layout.dart';
import '../setup/setup_status.dart';
import '../setup/setup_widgets.dart';

/// App setup: every permission and phone setting the app uses, with live
/// status and a fix button each. Re-checks when you come back to the app.
class AppSetupScreen extends ConsumerStatefulWidget {
  const AppSetupScreen({super.key});

  @override
  ConsumerState<AppSetupScreen> createState() => _AppSetupScreenState();
}

class _AppSetupScreenState extends ConsumerState<AppSetupScreen> with WidgetsBindingObserver {
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
    final status = ref.watch(setupStatusProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('App setup'), actions: [
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
              data: (s) => s == null ? const SizedBox.shrink() : _Checklist(s),
            ),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist(this.s);
  final SetupStatus s;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final missing = s.missingRequired;
    return ListView(padding: pagePadding(context, extra: 24), children: [
      Card(
        color: missing.isEmpty ? scheme.primaryContainer : scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(missing.isEmpty ? Icons.check_circle : Icons.warning_amber),
            const SizedBox(width: 12),
            Expanded(
              child: Text(missing.isEmpty
                  ? 'All set. Messages send through your SIM, scheduled runs start on time even with the app closed, '
                      'and sends continue if you leave the app.'
                  : '${missing.length} required ${missing.length == 1 ? 'item is' : 'items are'} missing. '
                      'Fix ${missing.length == 1 ? 'it' : 'them'} below so sending and schedules work reliably.'),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      for (final i in s.items) SetupItemCard(item: i, status: s),
    ]);
  }
}
