import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import 'chats_providers.dart';

/// Contacts++ chats in the Messages tab (signed in). Shows the saved list
/// at once and refreshes behind it; pull down to refresh now.
class ChatsList extends ConsumerWidget {
  const ChatsList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(chatsProvider);
    return chats.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Chats couldn’t load',
        text: 'Check your connection and try again.',
        action: OutlinedButton.icon(
          onPressed: () => ref.invalidate(chatsProvider),
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ),
      data: (list) => RefreshIndicator(
        onRefresh: () => ref.read(chatsProvider.notifier).refresh(),
        child: list.isEmpty
            ? ListView(children: const [
                SizedBox(
                  height: 420,
                  child: EmptyState(
                    icon: Icons.forum_outlined,
                    title: 'No chats yet',
                    text: 'When you text someone who is on Contacts++, it goes as a chat and shows up here. '
                        'Their replies arrive here and in Contacts++.',
                  ),
                ),
              ])
            : ListView.builder(
                padding: pagePadding(context, extra: fabClearance).copyWith(left: 0, right: 0, top: 6),
                itemCount: list.length,
                itemBuilder: (context, i) => _ChatTile(list[i]),
              ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile(this.chat);
  final ChatSummary chat;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final at = chat.lastMessageAt;
    final when = at == null
        ? ''
        : DateUtils.isSameDay(at, DateTime.now())
            ? TimeOfDay.fromDateTime(at).format(context)
            : MaterialLocalizations.of(context).formatShortMonthDay(at);
    final unread = chat.unread > 0;
    return ListTile(
      leading: InitialsAvatar(chat.title),
      title: Text(chat.title,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
      subtitle: Text('${chat.lastMessageIsMine ? 'You: ' : ''}${chat.lastMessage ?? ''}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(when, style: TextStyle(fontSize: 12, color: c.muted)),
        if (unread) ...[
          const SizedBox(height: 4),
          StatusTag('${chat.unread}', tone: Tone.success),
        ],
      ]),
      onTap: () => context.push(Uri(path: '/messages/chat/${chat.id}', queryParameters: {'title': chat.title}).toString()),
    );
  }
}
