import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/settings_providers.dart';
import '../settings/send_settings_screen.dart';
import 'setup_status.dart';
import 'setup_widgets.dart';
import '../../app/app_info.dart';

sealed class _Step {
  const _Step();
}

class _Welcome extends _Step {
  const _Welcome();
}

class _Permission extends _Step {
  const _Permission(this.item);
  final SetupItem item;
}

class _Country extends _Step {
  const _Country();
}

class _Done extends _Step {
  const _Done();
}

/// First-launch setup: one screen per permission/setting with why it's
/// needed, then the default country. Required items can be skipped, but the
/// app keeps warning until they're on.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> with WidgetsBindingObserver {
  int _index = 0;
  bool _finishing = false;

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
    // Back from a system settings page: re-check what's on.
    if (state == AppLifecycleState.resumed) ref.read(backgroundStatusVersionProvider.notifier).state++;
  }

  List<_Step> _steps(SetupStatus? s) => [
        const _Welcome(),
        if (s != null) for (final i in s.items) _Permission(i),
        const _Country(),
        const _Done(),
      ];

  Future<void> _finish() async {
    setState(() => _finishing = true);
    await ref.read(settingsRepositoryProvider).setFlag('onboarding_done', true);
    ref.read(dataVersionProvider.notifier).state++;
    if (mounted) context.go('/messages');
  }

  @override
  Widget build(BuildContext context) {
    final hasBg = ref.watch(backgroundSendServiceProvider) != null;
    final statusAsync = ref.watch(setupStatusProvider);
    if (hasBg && !statusAsync.hasValue) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final status = statusAsync.valueOrNull;
    final steps = _steps(status);
    final step = steps[_index.clamp(0, steps.length - 1)];
    void next() => setState(() => _index = (_index + 1).clamp(0, steps.length - 1));
    void back() => setState(() => _index = (_index - 1).clamp(0, steps.length - 1));

    final (Widget body, Widget primary) = switch (step) {
      _Welcome() => (
          const _Page(
            icon: Icons.sms_outlined,
            title: 'Welcome to $appName',
            text: 'Send personalised text messages to your groups through your own SIM, now or on a schedule.\n\n'
                'Your carrier\'s normal SMS charges apply.\n\n'
                'The next few steps turn on what the app needs. It takes about a minute.',
          ),
          FilledButton(onPressed: next, child: const Text('Get started')),
        ),
      _Permission(:final item) => (
          _PermissionPage(item: item, status: status!),
          FilledButton(
            onPressed: next,
            child: Text(status.isOk(item) ? 'Next' : 'Skip for now'),
          ),
        ),
      _Country() => (const _CountryPage(), FilledButton(onPressed: next, child: const Text('Next'))),
      _Done() => (
          _DonePage(status: status),
          FilledButton(onPressed: _finishing ? null : _finish, child: const Text('Start using the app')),
        ),
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index > 0) back();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(children: [
            LinearProgressIndicator(value: (_index + 1) / steps.length),
            Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: body)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(children: [
                if (_index > 0) TextButton(onPressed: back, child: const Text('Back')),
                const SizedBox(width: 8),
                // Flexible so long labels / large text sizes wrap instead of overflowing.
                Expanded(child: Align(alignment: Alignment.centerRight, child: primary)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.icon, required this.title, required this.text, this.child});
  final IconData icon;
  final String title, text;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 24),
        Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(text, style: Theme.of(context).textTheme.bodyLarge),
        if (child != null) ...[const SizedBox(height: 24), child!],
      ]);
}

const _icons = <SetupItem, IconData>{
  SetupItem.sms: Icons.sim_card_outlined,
  SetupItem.notifications: Icons.notifications_outlined,
  SetupItem.exactAlarms: Icons.alarm,
  SetupItem.battery: Icons.battery_charging_full,
  SetupItem.contacts: Icons.contacts_outlined,
};

class _PermissionPage extends ConsumerWidget {
  const _PermissionPage({required this.item, required this.status});
  final SetupItem item;
  final SetupStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = setupInfoFor(item);
    final ok = status.isOk(item);
    final scheme = Theme.of(context).colorScheme;
    return _Page(
      icon: _icons[item]!,
      title: info.title,
      text: info.why,
      child: ok
          ? Row(children: [
              Icon(Icons.check_circle, color: scheme.primary),
              const SizedBox(width: 8),
              const Text('On'),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SetupItemCard(item: item, status: status),
              if (status.isRequired(item))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('You can skip this, but the app will keep reminding you until it\'s on.',
                      style: TextStyle(color: scheme.error)),
                ),
            ]),
    );
  }
}

class _CountryPage extends ConsumerWidget {
  const _CountryPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final region = ref.watch(defaultRegionProvider);
    return _Page(
      icon: Icons.public,
      title: 'Your country',
      text: 'Phone numbers saved or imported without a +country code are read as numbers from this country. '
          'You can change it later in Settings.',
      child: DropdownMenu<String>(
        initialSelection: region,
        enableFilter: true,
        requestFocusOnTap: true,
        expandedInsets: EdgeInsets.zero,
        menuHeight: 320,
        dropdownMenuEntries: [for (final c in countryOptions) DropdownMenuEntry(value: c.code, label: c.label)],
        onSelected: (v) async {
          if (v == null) return;
          ref.read(defaultRegionProvider.notifier).state = v;
          final repo = ref.read(settingsRepositoryProvider);
          await repo.save((await repo.load()).copyWith(defaultRegion: v));
        },
      ),
    );
  }
}

class _DonePage extends StatelessWidget {
  const _DonePage({required this.status});
  final SetupStatus? status;

  @override
  Widget build(BuildContext context) {
    final missing = status?.missingRequired ?? const [];
    final scheme = Theme.of(context).colorScheme;
    return _Page(
      icon: missing.isEmpty ? Icons.check_circle_outline : Icons.warning_amber,
      title: missing.isEmpty ? 'You\'re all set' : 'Almost there',
      text: missing.isEmpty
          ? 'Everything the app needs is on. Start by adding contacts or importing them, then create a campaign.'
          : 'These are still off. The app will remind you until they\'re on; you can fix them anytime in '
              'Settings › App setup.',
      child: missing.isEmpty
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final i in missing)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.error_outline, color: scheme.error),
                  title: Text(setupInfoFor(i).title),
                  subtitle: Text(setupInfoFor(i).ifMissing ?? ''),
                ),
            ]),
    );
  }
}
