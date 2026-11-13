import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/features/chats/merged_inbox.dart';
import 'package:sim_bulk_sms/platform/contacts_plus/contacts_chat_service.dart';
import 'package:sim_bulk_sms/platform/messages/messages_service.dart';

void main() {
  ConversationSummary text(int id, String number, DateTime at, {String? name, int unread = 0}) =>
      ConversationSummary(threadId: id, addresses: [number], name: name, snippet: 'sms $id', date: at, unread: unread);
  ChatSummary chat(String id, String user, DateTime at, {int unread = 0}) =>
      ChatSummary(id: id, title: 'Chat $user', otherUserId: user, lastMessage: 'chat $id', lastMessageAt: at, unread: unread);

  test('one row per person: their texts and chat together, newest first', () {
    final merged = mergeInbox(
      [
        text(1, '+2348031111111', DateTime(2026, 11, 12, 9), name: 'Bola', unread: 1),
        text(2, '+2348032222222', DateTime(2026, 11, 12, 8)),
      ],
      [
        chat('c-bola', 'u-bola', DateTime(2026, 11, 12, 10), unread: 2),
        chat('c-dayo', 'u-dayo', DateTime(2026, 11, 12, 7)),
      ],
      {1: 'u-bola'},
    );
    expect(merged.map((e) => e.title), ['Bola', '+2348032222222', 'Chat u-dayo']);
    final bola = merged.first;
    expect(bola.both, isTrue);
    expect(bola.unread, 3);
    expect(bola.latestSource, MessageSource.chat);
    expect(bola.snippet, 'chat c-bola');
    expect(merged[1].latestSource, MessageSource.sms);
    expect(merged[2].text, isNull);
  });

  test('a chat joins only one text thread', () {
    final merged = mergeInbox(
      [text(1, '+1', DateTime(2026)), text(2, '+1', DateTime(2025))],
      [chat('c', 'u', DateTime(2024))],
      {1: 'u', 2: 'u'},
    );
    expect(merged.where((e) => e.chat != null), hasLength(1));
    expect(merged, hasLength(2));
  });
}
