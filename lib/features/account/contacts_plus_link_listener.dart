import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart' as app_links;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../../platform/contacts_plus/contacts_plus_auth.dart';
import '../../platform/contacts_plus/messages_push_service.dart';
import '../../platform/ios_integration/ios_integration_service.dart';
import '../backup/backup_controller.dart';
import '../chats/chats_providers.dart';
import '../phonebook/phonebook_controller.dart';
import '../relay/relay_controller.dart';
import 'account_controller.dart';

/// Messenger for app-wide notices (sign-in finished, sign-in failed…).
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Listens for `messagesplus://` links: the Contacts++ sign-in callback now,
/// and the cross-app links added later (open a thread, a web-queued run…).
class ContactsPlusLinkListener extends ConsumerStatefulWidget {
  const ContactsPlusLinkListener({super.key, required this.child, this.onAppLink});
  final Widget child;

  /// Other `messagesplus://` links, for the router.
  final void Function(Uri uri)? onAppLink;

  @override
  ConsumerState<ContactsPlusLinkListener> createState() => _ContactsPlusLinkListenerState();
}

class _ContactsPlusLinkListenerState extends ConsumerState<ContactsPlusLinkListener> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _links, _pushLinks;
  StreamSubscription<Map<String, dynamic>>? _pushData;
  Timer? _report;
  final _seen = <String>{};

  /// Widget tests run without the native plugins (links, push, secure storage).
  static final _inTest = Platform.environment.containsKey('FLUTTER_TEST');

  @override
  void initState() {
    super.initState();
    if (_inTest) return;
    final links = app_links.AppLinks();
    // uriLinkStream also replays the link that launched the app.
    _links = links.uriLinkStream.listen(_handle, onError: (_) {});
    final push = MessagesPushService.instance;
    _pushLinks = push.links.stream.listen((uri) => widget.onAppLink?.call(uri));
    _pushData = push.foreground.stream.listen((data) {
      if (data['category'] == 'messages') ref.read(chatsProvider.notifier).refresh();
      if (data['type'] == 'relay') unawaited(ref.read(relayControllerProvider).run());
      // A campaign, contact or group changed on the web: bring it here now.
      if (data['type'] == 'sync') unawaited(ref.read(backupControllerProvider.notifier).syncWeb(force: true));
    });
    // Results of texts sent for the web go back within a minute; web changes
    // and campaign progress sync every few minutes while the app is open.
    var ticks = 0;
    _report = Timer.periodic(const Duration(minutes: 1), (_) {
      ref.read(relayControllerProvider).reportResults();
      if (++ticks % 3 == 0) unawaited(ref.read(backupControllerProvider.notifier).syncWeb());
    });
    push.activate(ref.read(contactsPlusAuthProvider));
    WidgetsBinding.instance.addObserver(this);
    _onOpen();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onOpen();
  }

  /// On start and on return: due backups (and anything else Contacts++ queued).
  /// Text from the Share Extension: into the conversation picked in the
  /// share sheet, or to the share screen to choose who gets it.
  Future<void> _openIncomingShare() async {
    final share = await IosIntegrationService().takeIncomingShare();
    if (share == null) return;
    final chat = share.conversation?.startsWith('chat:') == true ? share.conversation!.substring(5) : null;
    widget.onAppLink?.call(chat != null
        ? Uri(scheme: 'messagesplus', host: 'messages', path: '/chat/$chat', queryParameters: {'draft': share.text})
        : Uri(scheme: 'messagesplus', host: 'messages', path: '/share', queryParameters: {'text': share.text}));
  }

  Future<void> _onOpen() async {
    // Siri, Spotlight or a Shortcuts action opened the app at a screen.
    final pending = await IosIntegrationService().takePendingLink();
    if (pending != null) widget.onAppLink?.call(pending);
    // A share that arrived while the app was closed.
    await _openIncomingShare();
    try {
      if (await ref.read(accountProvider.future) == null) return;
      await ref.read(relayControllerProvider).run();
      await ref.read(backupControllerProvider.notifier).runIfDue();
    } catch (_) {
      // Background work: tried again on the next return to the app.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _report?.cancel();
    _links?.cancel();
    _pushLinks?.cancel();
    _pushData?.cancel();
    super.dispose();
  }

  Future<void> _handle(Uri incoming) async {
    // The sign-in callback keeps its code, so it skips the link conversion.
    final uri = ContactsPlusAuth.isCallback(incoming) ? incoming : webLinkToApp(incoming);
    if (uri == null) return;
    // Platforms can deliver the same launch link twice.
    if (!_seen.add(uri.toString())) return;
    if (uri.host == 'messages' && uri.path == '/share-incoming') {
      _seen.remove(uri.toString()); // the same link comes back with every share
      await _openIncomingShare();
      return;
    }
    if (!ContactsPlusAuth.isCallback(uri)) {
      // "Texts from the web are waiting": fetch them first.
      if (uri.host == 'messages' && uri.path.startsWith('/relay')) await ref.read(relayControllerProvider).run();
      widget.onAppLink?.call(uri);
      return;
    }
    final messenger = appMessengerKey.currentState;
    try {
      final account = await ref.read(accountProvider.notifier).completeSignIn(uri);
      // Chats reach this phone from now on.
      unawaited(MessagesPushService.instance.requestPermission(ref.read(contactsPlusAuthProvider)));
      // "Chat" actions appear on Contacts++ members in the phone's Contacts app.
      unawaited(ref.read(phonebookControllerProvider).refresh());
      // Campaigns and people set up on the web arrive straight away.
      unawaited(ref.read(backupControllerProvider.notifier).syncWeb(force: true));
      messenger?.showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_outline, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(child: Text('Signed in as ${account.displayName}')),
        ]),
      ));
    } on ContactsPlusException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger?.showSnackBar(const SnackBar(content: Text('Sign-in didn’t finish. Try again.')));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Links from Contacts++ and Events++ are web addresses
/// (contacts.comeriver.com/messages/…) that the installed app opens; they
/// map to the app's own `messagesplus://` links. Null: not for Messages++.
Uri? webLinkToApp(Uri uri) {
  if (uri.scheme == 'messagesplus') return uri;
  if (uri.scheme != 'https' || uri.host != 'contacts.comeriver.com' || !uri.path.startsWith('/messages')) return null;
  final q = uri.queryParameters;
  final action = uri.pathSegments.length > 1 ? uri.pathSegments[1] : '';
  return switch (action) {
    'text' => Uri(scheme: 'messagesplus', host: 'messages', path: '/compose', queryParameters: {
        if (q['to'] != null) 'to': q['to']!,
        if (q['text'] != null) 'body': q['text']!,
      }),
    'group' => Uri(scheme: 'messagesplus', host: 'campaigns', path: '/new', queryParameters: q['text'] == null ? null : {'text': q['text']!}),
    _ => Uri(scheme: 'messagesplus', host: 'messages'),
  };
}
