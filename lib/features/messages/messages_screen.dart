import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/app_info.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/settings_providers.dart';
import '../../app/theme.dart';
import '../../platform/messages/messages_service.dart';
import '../campaigns/campaign_labels.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../setup/setup_banner.dart';

/// Numbers our campaigns texted in the last 30 days (for the "Campaign replies" filter).
final _campaignNumbersProvider = FutureProvider<Set<String>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(campaignRepositoryProvider).recentlyTextedNumbers(DateTime.now().subtract(const Duration(days: 30)));
});

enum _Filter { all, unread, campaign }

/// The Messages tab (home): the phone's conversations, while this is the
/// default messaging app. Otherwise it explains and offers to become default.
class MessagesScreen extends ConsumerStatefulWidget {
  const MessagesScreen({super.key});

  @override
  ConsumerState<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends ConsumerState<MessagesScreen> {
  String _query = '';
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(messagesServiceProvider);
    final isDefault = ref.watch(isDefaultSmsProvider).valueOrNull;
    final conversations = ref.watch(conversationsProvider);
    final setup = ref.watch(setupStatusProvider).valueOrNull;

    Widget body;
    if (svc == null) {
      body = const EmptyState(
        icon: Icons.forum_outlined,
        title: 'Texts live in your Messages app',
        text: 'On this phone, conversations stay in the Messages app. Campaigns open it for each message.',
      );
    } else if (isDefault == false) {
      body = EmptyState(
        icon: Icons.forum_outlined,
        title: 'Your texts, here',
        text: 'Make $appName your default messaging app to read and reply to texts here and send campaigns '
            'automatically. Your existing messages stay where they are, and you can switch back anytime.',
        action: FilledButton.icon(
          onPressed: () async {
            final ok = await svc.requestDefault();
            if (!ok) await svc.openDefaultAppsSettings();
            ref.invalidate(capabilitiesProvider);
            ref.read(messagesVersionProvider.notifier).state++;
          },
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Make default messaging app'),
        ),
      );
    } else {
      body = conversations.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(child: Text('Could not read your messages.')),
        data: (all) => _list(all),
      );
    }

    final unread = (conversations.valueOrNull ?? const <ConversationSummary>[]).fold<int>(0, (n, c) => n + c.unread);
    return Scaffold(
      floatingActionButton: svc == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'fab-messages',
              onPressed: () => context.push('/messages/new'),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('New message'),
            ),
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          TabTitle('Messages',
              trailing: isDefault == true && unread > 0
                  ? IconButton(
                      tooltip: 'Mark all as read',
                      icon: const Icon(Icons.done_all),
                      onPressed: () async {
                        await svc!.markAllRead();
                        ref.read(messagesVersionProvider.notifier).state++;
                      },
                    )
                  : null),
          if (setup != null && !setup.complete)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: SetupBanner(missing: setup.missingRequired)),
          if (isDefault == true) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search messages and people'),
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              ),
            ),
            SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                for (final (f, label) in const [(_Filter.all, 'All'), (_Filter.unread, 'Unread'), (_Filter.campaign, 'Campaign replies')])
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

  Widget _list(List<ConversationSummary> all) {
    final normalizer = ref.watch(phoneNormalizerProvider);
    final campaignNumbers = ref.watch(_campaignNumbersProvider).valueOrNull ?? const <String>{};
    bool fromCampaign(ConversationSummary c) =>
        c.addresses.any((a) => campaignNumbers.contains(normalizer.normalize(a).e164 ?? a));
    final shown = all.where((c) {
      if (_filter == _Filter.unread && c.unread == 0) return false;
      if (_filter == _Filter.campaign && !fromCampaign(c)) return false;
      if (_query.isEmpty) return true;
      return c.title.toLowerCase().contains(_query) || c.snippet.toLowerCase().contains(_query) ||
          c.addresses.any((a) => a.replaceAll(RegExp(r'\D'), '').contains(_query.replaceAll(RegExp(r'\D'), '')) &&
              _query.replaceAll(RegExp(r'\D'), '').isNotEmpty);
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
            ListTile(leading: const Icon(Icons.mark_chat_read_outlined), title: const Text('Mark as read'),
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
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
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
                  child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
                ),
                Text(formatWhen(c.date), style: TextStyle(fontSize: 12, color: muted)),
              ]),
              const SizedBox(height: 2),
              Row(children: [
                Expanded(
                  child: Text(c.snippet, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: unread ? Theme.of(context).colorScheme.onSurface : muted,
                          fontWeight: unread ? FontWeight.w600 : FontWeight.w400)),
                ),
                if (unread)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(999)),
                    child: Text('${c.unread}',
                        style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
