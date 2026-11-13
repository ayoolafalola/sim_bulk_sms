import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/app_info.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/settings_providers.dart';
import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../../platform/messages/messages_service.dart';
import '../account/account_controller.dart';
import '../account/profile_button.dart';
import '../campaigns/campaign_labels.dart';
import '../chats/chats_list.dart';
import '../chats/chats_providers.dart';
import '../chats/merged_inbox.dart';
import '../relay/relay_controller.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../setup/setup_banner.dart';

/// Numbers our campaigns texted in the last 30 days (for the "Campaign replies" filter).
final _campaignNumbersProvider = FutureProvider<Set<String>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(campaignRepositoryProvider).recentlyTextedNumbers(DateTime.now().subtract(const Duration(days: 30)));
});

enum _Filter { all, unread, campaign }

/// Which list the Messages tab shows.
enum _View { all, texts, chats }

/// The Messages tab (home).
///
/// Android, as the default messaging app: All (texts and Contacts++ chats
/// merged, one row per person), Texts, and Chats. Anywhere texts can't be
/// shown here (iPhone, or Android while another app handles texts) it is
/// Contacts++ chats only, never blank: signed out, it asks to sign in.
class MessagesScreen extends ConsumerStatefulWidget {
  const MessagesScreen({super.key});

  @override
  ConsumerState<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends ConsumerState<MessagesScreen> {
  String _query = '';
  _Filter _filter = _Filter.all;
  _View _view = _View.all;

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(messagesServiceProvider);
    final isDefault = ref.watch(isDefaultSmsProvider).valueOrNull;
    final conversations = ref.watch(conversationsProvider);
    final setup = ref.watch(setupStatusProvider).valueOrNull;
    final accountState = ref.watch(accountProvider);
    final signedIn = accountState.valueOrNull != null;
    final unreadChats = ref.watch(unreadChatsProvider);
    // Texts live here only on Android while this is the default messaging app.
    final hasTexts = svc != null && isDefault == true;
    final view = !hasTexts ? _View.chats : (signedIn ? _view : _View.texts);
    final searchable = hasTexts && view != _View.chats;

    Widget body;
    if (svc != null && isDefault == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (view == _View.chats) {
      body = accountState.isLoading && !accountState.hasValue
          ? const Center(child: CircularProgressIndicator())
          : signedIn
              ? const ChatsList()
              : const _ChatsSignIn();
    } else if (view == _View.all) {
      body = ref.watch(mergedInboxProvider).when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => const Center(child: Text('Could not read your messages.')),
            data: _mergedList,
          );
    } else {
      body = conversations.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Could not read your messages.')),
        data: (all) => _list(all),
      );
    }

    final unread = (conversations.valueOrNull ?? const <ConversationSummary>[]).fold<int>(0, (n, c) => n + c.unread);
    final Widget? fab = hasTexts
        ? FloatingActionButton.extended(
            heroTag: 'fab-messages',
            onPressed: () => context.push(view == _View.chats ? '/messages/new-chat' : '/messages/new'),
            icon: const Icon(Icons.edit_outlined),
            label: Text(view == _View.chats ? 'New chat' : 'New message'),
          )
        : signedIn
            ? FloatingActionButton.extended(
                heroTag: 'fab-messages',
                onPressed: () => context.push('/messages/new-chat'),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('New chat'),
              )
            : null;
    return Scaffold(
      floatingActionButton: fab,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          TabTitle('Messages',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (hasTexts && view != _View.chats && unread > 0)
                  IconButton(
                    tooltip: 'Mark all as read',
                    icon: const Icon(Icons.done_all),
                    onPressed: () async {
                      await svc.markAllRead();
                      ref.read(messagesVersionProvider.notifier).state++;
                    },
                  ),
                const ProfileButton(),
              ])),
          // Banners, switch, search and filters: never more than most of the
          // screen (small phones, large text); they scroll if they need to.
          LayoutBuilder(
            builder: (context, box) => ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
              child: SingleChildScrollView(
                child: Column(children: [
                  if (setup != null && !setup.complete)
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16), child: SetupBanner(missing: setup.missingRequired)),
                  if (ref.watch(relayWaitingProvider).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Material(
                        color: AppColors.of(context).infoBg,
                        borderRadius: BorderRadius.circular(16),
                        child: ListTile(
                          leading: Icon(Icons.laptop_outlined, color: AppColors.of(context).infoFg),
                          title: Text(
                              '${ref.watch(relayWaitingProvider).length == 1 ? 'A send' : '${ref.watch(relayWaitingProvider).length} sends'} from the web '
                              'need you to tap Send',
                              style: TextStyle(color: AppColors.of(context).infoFg, fontWeight: FontWeight.w700)),
                          trailing: FilledButton.tonalIcon(
                            onPressed: () {
                              final waiting = ref.read(relayWaitingProvider);
                              ref.read(relayWaitingProvider.notifier).state = waiting.skip(1).toList();
                              context.push('/campaigns/${waiting.first}');
                            },
                            icon: const Icon(Icons.send_outlined),
                            label: const Text('Open'),
                          ),
                        ),
                      ),
                    ),
                  // Android while another app handles texts: chats work here; offer the rest.
                  if (svc != null && isDefault == false) _MakeDefaultStrip(svc: svc),
                  if (hasTexts && signedIn)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: SegmentedButton<_View>(
                        showSelectedIcon: false,
                        segments: [
                          const ButtonSegment(value: _View.all, icon: Icon(Icons.all_inbox_outlined), label: Text('All')),
                          const ButtonSegment(value: _View.texts, icon: Icon(Icons.sms_outlined), label: Text('Texts')),
                          ButtonSegment(
                              value: _View.chats,
                              icon: const Icon(Icons.forum_outlined),
                              label: Text(unreadChats > 0 ? 'Chats · $unreadChats' : 'Chats')),
                        ],
                        selected: {view},
                        onSelectionChanged: (v) => setState(() => _view = v.first),
                      ),
                    ),
                  if (searchable) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: TextField(
                        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search messages and people'),
                        onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                      ),
                    ),
                    SizedBox(
                      height: 44,
                      child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          children: [
                            for (final (f, label) in const [
                              (_Filter.all, 'All'),
                              (_Filter.unread, 'Unread'),
                              (_Filter.campaign, 'Campaign replies')
                            ])
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(label),
                                  selected: _filter == f,
                                  showCheckmark: false,
                                  onSelected: (_) => setState(() => _filter = f),
                                ),
                              ),
                          ]),
                    ),
                    const SizedBox(height: 8),
                  ],
                ]),
              ),
            ),
          ),
          Expanded(
            child: Material(
              color: AppColors.of(context).surface,
              clipBehavior: Clip.antiAlias,
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
              child: body,
            ),
          ),
        ]),
      ),
    );
  }

  bool _matchesQuery(String title, String snippet, List<String> addresses) {
    if (_query.isEmpty) return true;
    final digits = _query.replaceAll(RegExp(r'\D'), '');
    return title.toLowerCase().contains(_query) ||
        snippet.toLowerCase().contains(_query) ||
        (digits.isNotEmpty && addresses.any((a) => a.replaceAll(RegExp(r'\D'), '').contains(digits)));
  }

  /// All: texts and chats, one row per person.
  Widget _mergedList(List<MergedEntry> all) {
    final normalizer = ref.watch(phoneNormalizerProvider);
    final campaignNumbers = ref.watch(_campaignNumbersProvider).valueOrNull ?? const <String>{};
    bool fromCampaign(MergedEntry e) =>
        e.text?.addresses.any((a) => campaignNumbers.contains(normalizer.normalize(a).e164 ?? a)) ?? false;
    final shown = all.where((e) {
      if (_filter == _Filter.unread && e.unread == 0) return false;
      if (_filter == _Filter.campaign && !fromCampaign(e)) return false;
      return _matchesQuery(e.title, e.snippet, e.text?.addresses ?? const []);
    }).toList();
    if (shown.isEmpty) {
      return EmptyState(
        icon: Icons.chat_bubble_outline,
        title: all.isEmpty ? 'No conversations yet' : 'Nothing here',
        text: all.isEmpty ? 'Texts and Contacts++ chats you send and receive appear here.' : 'Try another filter or search.',
      );
    }
    return RefreshIndicator(
      onRefresh: () async {
        ref.read(messagesVersionProvider.notifier).state++;
        await ref.read(chatsProvider.notifier).refresh();
      },
      child: ListView.builder(
        padding: pagePadding(context, extra: fabClearance).copyWith(left: 0, right: 0, top: 6),
        itemCount: shown.length,
        itemBuilder: (context, i) => _MergedTile(shown[i]),
      ),
    );
  }

  Widget _list(List<ConversationSummary> all) {
    final normalizer = ref.watch(phoneNormalizerProvider);
    final campaignNumbers = ref.watch(_campaignNumbersProvider).valueOrNull ?? const <String>{};
    bool fromCampaign(ConversationSummary c) =>
        c.addresses.any((a) => campaignNumbers.contains(normalizer.normalize(a).e164 ?? a));
    final shown = all.where((c) {
      if (_filter == _Filter.unread && c.unread == 0) return false;
      if (_filter == _Filter.campaign && !fromCampaign(c)) return false;
      return _matchesQuery(c.title, c.snippet, c.addresses);
    }).toList();
    if (shown.isEmpty) {
      return EmptyState(
        icon: Icons.chat_bubble_outline,
        title: all.isEmpty ? 'No conversations yet' : 'Nothing here',
        text: all.isEmpty ? 'Texts you send and receive appear here.' : 'Try another filter or search.',
      );
    }
    return ListView.builder(
      padding: pagePadding(context, extra: fabClearance).copyWith(left: 0, right: 0, top: 6),
      itemCount: shown.length,
      itemBuilder: (context, i) => ConversationTile(shown[i]),
    );
  }
}

class ConversationTile extends ConsumerWidget {
  const ConversationTile(this.c, {super.key});
  final ConversationSummary c;

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final svc = ref.read(messagesServiceProvider);
    if (svc == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: InitialsAvatar(c.title), title: Text(c.title)),
          const Divider(),
          if (c.unread > 0)
            ListTile(
                leading: const Icon(Icons.mark_chat_read_outlined),
                title: const Text('Mark as read'),
                onTap: () => Navigator.pop(ctx, 'read')),
          ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text('Delete conversation', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (action == 'read') {
      await svc.markRead(c.threadId);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete conversation with ${c.title}?'),
          content: const Text('All its messages are deleted from this phone, also from other messaging apps.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true), icon: const Icon(Icons.delete_outline), label: const Text('Delete')),
          ],
        ),
      );
      if (ok == true) await svc.deleteThread(c.threadId);
    }
    ref.read(messagesVersionProvider.notifier).state++;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = c.unread > 0;
    final muted = AppColors.of(context).muted;
    return InkWell(
      onTap: () => context.push('/messages/thread/${c.threadId}'),
      onLongPress: () => _actions(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(children: [
          InitialsAvatar(c.title, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
                ),
                Text(formatWhen(c.date), style: TextStyle(fontSize: 12, color: muted)),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                Expanded(
                  child: Text(c.snippet,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: unread ? Theme.of(context).colorScheme.onSurface : muted,
                          fontWeight: unread ? FontWeight.w600 : FontWeight.w400)),
                ),
                if (unread)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration:
                        BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(999)),
                    child: Text('${c.unread}',
                        style:
                            TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// One person in All: their latest message, marked SMS or Chat, and both
/// unread counts together. Opens one timeline with texts and chats.
class _MergedTile extends StatelessWidget {
  const _MergedTile(this.e);
  final MergedEntry e;

  void _open(BuildContext context) {
    final t = e.text, c = e.chat;
    if (t != null) {
      context.push(Uri(path: '/messages/thread/${t.threadId}', queryParameters: c == null ? null : {'chat': c.id}).toString());
    } else {
      context.push(Uri(path: '/messages/chat/${c!.id}', queryParameters: {'title': c.title}).toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = e.unread > 0;
    final muted = AppColors.of(context).muted;
    final scheme = Theme.of(context).colorScheme;
    final chat = e.latestSource == MessageSource.chat;
    return InkWell(
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(children: [
          Stack(clipBehavior: Clip.none, children: [
            InitialsAvatar(e.title, size: 48),
            if (e.chat != null)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                      color: scheme.tertiary,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.of(context).surface, width: 2)),
                  child: Icon(Icons.forum, size: 11, color: scheme.onTertiary),
                ),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
                ),
                Text(formatWhen(e.date), style: TextStyle(fontSize: 12, color: muted)),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                Tooltip(
                  message: chat ? 'Latest message: Contacts++ chat' : 'Latest message: SMS',
                  child: Icon(chat ? Icons.forum_outlined : Icons.sms_outlined, size: 15, color: chat ? scheme.tertiary : muted),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(e.snippet,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: unread ? scheme.onSurface : muted,
                          fontWeight: unread ? FontWeight.w600 : FontWeight.w400)),
                ),
                if (unread)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(999)),
                    child:
                        Text('${e.unread}', style: TextStyle(color: scheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Chats while signed out (iPhone; Android while another app handles texts):
/// one tap to sign in with Contacts++, then the chats appear here.
class _ChatsSignIn extends ConsumerStatefulWidget {
  const _ChatsSignIn();

  @override
  ConsumerState<_ChatsSignIn> createState() => _ChatsSignInState();
}

class _ChatsSignInState extends ConsumerState<_ChatsSignIn> {
  bool _opening = false;

  Future<void> _signIn() async {
    setState(() => _opening = true);
    try {
      await ref.read(accountProvider.notifier).signIn();
    } on ContactsPlusException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.forum_outlined,
        title: 'Chat with your Contacts++ people',
        text: 'Sign in with Contacts++ to chat with anyone in your contacts who uses it, '
            'on every device they have. Your password and phonebook are never shared.',
        action: FilledButton.icon(
          onPressed: _opening ? null : _signIn,
          icon: _opening
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.login),
          label: Text(_opening ? 'Opening Contacts++…' : 'Sign in with Contacts++'),
        ),
      );
}

/// Android while another app handles texts: Messages++ shows chats like on
/// iPhone; becoming the default adds the phone's texts, merged.
class _MakeDefaultStrip extends ConsumerWidget {
  const _MakeDefaultStrip({required this.svc});
  final MessagesService svc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Material(
        color: c.infoBg,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.sms_outlined, color: c.infoFg),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Make $appName your default messaging app to see your texts here, merged with chats.',
                    style: TextStyle(color: c.infoFg, fontWeight: FontWeight.w600)),
              ),
            ]),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton.tonal(
                onPressed: () async {
                  final ok = await svc.requestDefault();
                  if (!ok) await svc.openDefaultAppsSettings();
                  ref.invalidate(capabilitiesProvider);
                  ref.read(messagesVersionProvider.notifier).state++;
                },
                child: const Text('Make default'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
