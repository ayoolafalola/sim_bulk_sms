import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/sending_providers.dart';
import '../../app/settings_providers.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/messages/messages_service.dart';
import 'chats_providers.dart';

/// Where a message (or a conversation's latest message) came from.
enum MessageSource { sms, chat }

/// One person in the merged "All" list: their texts, their Contacts++ chat, or both.
class MergedEntry {
  const MergedEntry({this.text, this.chat});
  final ConversationSummary? text;
  final ChatSummary? chat;

  DateTime get date {
    final t = text?.date, c = chat?.lastMessageAt;
    if (t == null) return c ?? DateTime.fromMillisecondsSinceEpoch(0);
    if (c == null) return t;
    return c.isAfter(t) ? c : t;
  }

  /// The source of the newest message.
  MessageSource get latestSource {
    if (text == null) return MessageSource.chat;
    if (chat?.lastMessageAt == null) return MessageSource.sms;
    return chat!.lastMessageAt!.isAfter(text!.date) ? MessageSource.chat : MessageSource.sms;
  }

  /// The phone's name for them first (it is the person's own address book), else Contacts++.
  String get title => text?.name?.trim().isNotEmpty == true ? text!.title : (chat?.title ?? text?.title ?? '');

  String get snippet => latestSource == MessageSource.chat
      ? '${chat!.lastMessageIsMine ? 'You: ' : ''}${chat!.lastMessage ?? ''}'
      : text!.snippet;

  int get unread => (text?.unread ?? 0) + (chat?.unread ?? 0);

  bool get both => text != null && chat != null;
}

/// Combines text threads and chats into one list, newest first. A one-to-one
/// text thread and a chat are the same person when the thread's number belongs
/// to the chat's Contacts++ member. Pure, for tests.
List<MergedEntry> mergeInbox(
    List<ConversationSummary> texts, List<ChatSummary> chats, Map<int, String> chatUserForThread) {
  final chatByUser = <String, ChatSummary>{
    for (final c in chats)
      if (c.otherUserId != null) c.otherUserId!: c,
  };
  final used = <String>{};
  final entries = <MergedEntry>[];
  for (final t in texts) {
    final user = chatUserForThread[t.threadId];
    final chat = user == null || used.contains(user) ? null : chatByUser[user];
    if (chat != null) used.add(chat.otherUserId!);
    entries.add(MergedEntry(text: t, chat: chat));
  }
  for (final c in chats) {
    if (c.otherUserId == null || !used.contains(c.otherUserId)) entries.add(MergedEntry(chat: c));
  }
  entries.sort((a, b) => b.date.compareTo(a.date));
  return entries;
}

/// Thread id → Contacts++ member id, for one-to-one text threads whose number
/// is on Contacts++ (looked up in batches and cached for hours by the service).
final chatUserForThreadProvider = FutureProvider<Map<int, String>>((ref) async {
  final texts = await ref.watch(conversationsProvider.future);
  final chats = ref.watch(chatsProvider).valueOrNull ?? const <ChatSummary>[];
  if (texts.isEmpty || chats.isEmpty) return const {};
  final normalizer = ref.watch(phoneNormalizerProvider);
  final numberOf = <int, String>{};
  for (final t in texts) {
    if (t.addresses.length != 1) continue;
    final e164 = normalizer.normalize(t.addresses.single).e164;
    if (e164 != null) numberOf[t.threadId] = e164;
  }
  final reach = await ref.watch(contactsChatServiceProvider).reachability(numberOf.values.toSet());
  return {
    for (final e in numberOf.entries)
      if (reach[e.value] != null) e.key: reach[e.value]!.userId,
  };
});

/// The merged "All" list (Android, default messaging app, signed in).
final mergedInboxProvider = Provider<AsyncValue<List<MergedEntry>>>((ref) {
  final texts = ref.watch(conversationsProvider);
  final chats = ref.watch(chatsProvider);
  final links = ref.watch(chatUserForThreadProvider).valueOrNull ?? const <int, String>{};
  if (texts.isLoading && !texts.hasValue) return const AsyncLoading();
  if (texts.hasError && chats.hasError) return AsyncError(texts.error!, texts.stackTrace ?? StackTrace.current);
  return AsyncData(mergeInbox(texts.valueOrNull ?? const [], chats.valueOrNull ?? const [], links));
});

/// The Contacts++ chat for a text thread, when that person is on Contacts++
/// and you already chat (for opening a thread with both in one timeline).
final chatForThreadProvider = Provider.family<ChatSummary?, int>((ref, threadId) {
  final user = ref.watch(chatUserForThreadProvider).valueOrNull?[threadId];
  if (user == null) return null;
  return (ref.watch(chatsProvider).valueOrNull ?? const <ChatSummary>[]).where((c) => c.otherUserId == user).firstOrNull;
});
