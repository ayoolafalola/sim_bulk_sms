import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../account/account_controller.dart';
import '../chats/chats_providers.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';

/// Text shared from another app (the share sheet): send it to a person, to
/// a group as a campaign, or into a Contacts++ chat.
class ShareTargetScreen extends ConsumerWidget {
  const ShareTargetScreen({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppColors.of(context);
    final chats = ref.watch(accountProvider).valueOrNull == null
        ? const <ChatSummary>[]
        : (ref.watch(chatsProvider).valueOrNull ?? const <ChatSummary>[]).take(8).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Share with Messages++')),
      body: ListView(padding: pagePadding(context, extra: 24), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: c.neutralBg, borderRadius: BorderRadius.circular(16)),
          child: Text(text.isEmpty ? '(nothing to share)' : text, maxLines: 8, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Text someone'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushReplacement(Uri(path: '/messages/new', queryParameters: {'body': text}).toString()),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: const Text('Send to a group'),
              subtitle: const Text('A campaign with this message'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushReplacement(Uri(path: '/campaigns/new', queryParameters: {'text': text}).toString()),
            ),
          ]),
        ),
        if (chats.isNotEmpty) ...[
          const SectionLabel('Contacts++ chats'),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (final chat in chats)
                ListTile(
                  leading: InitialsAvatar(chat.title, size: 36),
                  title: Text(chat.title),
                  trailing: IconButton(
                    tooltip: 'Send to ${chat.title}',
                    icon: const Icon(Icons.send_outlined),
                    onPressed: () => _sendToChat(context, ref, chat),
                  ),
                  onTap: () => _sendToChat(context, ref, chat),
                ),
            ]),
          ),
        ],
      ]),
    );
  }

  Future<void> _sendToChat(BuildContext context, WidgetRef ref, ChatSummary chat) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(contactsChatServiceProvider)
          .sendInConversation(chat.id, text, clientId: ContactsChatService.newClientId());
      if (context.mounted) {
        context.pushReplacement(Uri(path: '/messages/chat/${chat.id}', queryParameters: {'title': chat.title}).toString());
      }
    } on ContactsPlusException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// "Chat with Messages++" from the phone's Contacts app: opens the Contacts++
/// chat, or a text conversation when the person can't get chats.
class ChatToScreen extends ConsumerStatefulWidget {
  const ChatToScreen({super.key, required this.phone, this.name});
  final String phone;
  final String? name;

  @override
  ConsumerState<ChatToScreen> createState() => _ChatToScreenState();
}

class _ChatToScreenState extends ConsumerState<ChatToScreen> {
  String _step = 'Checking whether they’re on Contacts++';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final text = Uri(path: '/messages/compose', queryParameters: {'to': widget.phone}).toString();
    if (ref.read(accountProvider).valueOrNull == null) {
      if (mounted) context.pushReplacement(text);
      return;
    }
    final service = ref.read(contactsChatServiceProvider);
    try {
      final target = (await service.reachability([widget.phone]).timeout(const Duration(seconds: 10)))[widget.phone];
      if (target == null) {
        if (mounted) context.pushReplacement(text);
        return;
      }
      setState(() => _step = 'Opening the chat');
      final id = await service.conversationWith(target);
      if (mounted) {
        context.pushReplacement(Uri(path: '/messages/chat/$id',
            queryParameters: {'title': target.displayName ?? widget.name ?? widget.phone}).toString());
      }
    } catch (_) {
      if (mounted) context.pushReplacement(text);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.name ?? widget.phone)),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_step),
          ]),
        ),
      );
}
