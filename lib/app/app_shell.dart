import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/contacts/contact_sync_runner.dart';
import '../features/pro/pro_controller.dart';
import 'providers.dart';
import 'sending_providers.dart';

/// Bottom navigation for the main tabs. Also: sends a fresh install to the
/// first-launch setup, keeps the inbox live (new texts, status updates), opens
/// the conversation a notification or another app asked for, and shows an
/// unread count on Messages and a dot on Settings while setup is incomplete.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  StreamSubscription<String>? _events;
  Timer? _contactsDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final svc = ref.read(messagesServiceProvider);
    if (svc != null) {
      _events = svc.events.listen((type) {
        if (type == 'contacts') {
          // The phone's contacts changed: sync the changes shortly (edits come in bursts).
          _contactsDebounce?.cancel();
          _contactsDebounce = Timer(const Duration(seconds: 2), _syncContacts);
          return;
        }
        ref.read(messagesVersionProvider.notifier).state++;
        if (type == 'launch') _openLaunch();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLaunch()); // opened from a notification / another app
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncContacts());
    ref.read(proControllerProvider).start(); // Pro status from Google Play / the App Store
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    _contactsDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncContacts(); // e.g. back from editing in the Contacts app
      ref.read(proControllerProvider).refresh(); // e.g. back from managing the subscription
    }
  }

  Future<void> _syncContacts() => ref.read(contactSyncRunnerProvider).run();

  Future<void> _openLaunch() async {
    final l = await ref.read(messagesServiceProvider)?.takeLaunch();
    if (l == null || !mounted) return;
    if (l.threadId != null) {
      context.push('/messages/thread/${l.threadId}');
    } else if (l.address != null && l.address!.isNotEmpty) {
      context.push(Uri(path: '/messages/compose', queryParameters: {'to': l.address!, if (l.body != null) 'body': l.body!})
          .toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(onboardingDoneProvider, (_, next) {
      if (next.valueOrNull == false) context.go('/welcome');
    });
    final setup = ref.watch(setupStatusProvider).valueOrNull;
    final setupMissing = setup != null && !setup.complete;
    final unread = (ref.watch(conversationsProvider).valueOrNull ?? const []).fold<int>(0, (n, c) => n + c.unread);
    final shell = widget.shell;
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        // Tapping the current tab again returns it to its top screen.
        onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
        destinations: [
          NavigationDestination(
            icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.chat_bubble_outline)),
            selectedIcon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.chat_bubble)),
            label: 'Messages',
          ),
          const NavigationDestination(
              icon: Icon(Icons.campaign_outlined), selectedIcon: Icon(Icons.campaign), label: 'Campaigns'),
          const NavigationDestination(
              icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Contacts'),
          NavigationDestination(
            icon: Badge(isLabelVisible: setupMissing, child: const Icon(Icons.settings_outlined)),
            selectedIcon: Badge(isLabelVisible: setupMissing, child: const Icon(Icons.settings)),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
