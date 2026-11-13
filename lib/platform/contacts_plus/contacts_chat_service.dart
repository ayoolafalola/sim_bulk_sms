import 'dart:math';

import 'contacts_plus_api.dart';
import 'contacts_plus_auth.dart';

/// A Contacts++ member who accepts chats from the signed-in member.
class ChatTarget {
  const ChatTarget({required this.userId, this.displayName});
  final String userId;
  final String? displayName;
}

/// A Contacts++ chat in the Messages tab.
class ChatSummary {
  const ChatSummary(
      {required this.id,
      required this.title,
      this.otherUserId,
      this.lastMessage,
      this.lastMessageAt,
      this.lastMessageIsMine = false,
      this.unread = 0});
  final String id, title;
  final String? otherUserId, lastMessage;
  final DateTime? lastMessageAt;
  final bool lastMessageIsMine;
  final int unread;

  static ChatSummary fromJson(Map<dynamic, dynamic> j) => ChatSummary(
        id: '${j['id']}',
        title: '${j['title'] ?? 'Conversation'}',
        otherUserId: j['other_user_id'] as String?,
        lastMessage: j['last_message'] as String?,
        lastMessageAt: DateTime.tryParse('${j['last_message_at'] ?? ''}')?.toLocal(),
        lastMessageIsMine: j['last_message_is_mine'] == true,
        unread: (j['unread_count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'other_user_id': otherUserId,
        'last_message': lastMessage,
        'last_message_at': lastMessageAt?.toUtc().toIso8601String(),
        'last_message_is_mine': lastMessageIsMine,
        'unread_count': unread,
      };
}

/// One message in a Contacts++ chat.
class ChatMessage {
  const ChatMessage(
      {required this.id,
      required this.senderId,
      required this.body,
      required this.at,
      this.clientId,
      this.type = 'text',
      this.state,
      this.deleted = false});
  final String id, senderId;
  final String? body, clientId, state;
  final String type;
  final DateTime at;
  final bool deleted;

  static ChatMessage fromJson(Map<dynamic, dynamic> j) => ChatMessage(
        id: '${j['id']}',
        senderId: '${j['sender_id']}',
        body: j['body'] as String?,
        clientId: j['client_id'] as String?,
        type: '${j['type'] ?? 'text'}',
        state: j['receipt_state'] as String?,
        deleted: j['deleted_at'] != null,
        at: DateTime.tryParse('${j['created_at']}')?.toLocal() ?? DateTime.now(),
      );
}

/// Result of handing one message to Contacts++.
enum ChatOutcome {
  /// Contacts++ accepted it; the person gets a chat on every device.
  sent,

  /// Contacts++ refused it (permissions changed, blocked, limits): nothing
  /// was sent, so a text can go instead.
  refused,

  /// No answer: it may or may not have arrived. Never followed by a text
  /// automatically (that could duplicate it).
  uncertain,
}

/// Contacts++ chats from Messages++: who can get one, and sending them.
///
/// Every message carries a random `client_id`, so the server ignores a
/// retried request instead of sending the message twice.
class ContactsChatService {
  ContactsChatService(this._auth, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final ContactsPlusAuth _auth;
  final DateTime Function() _clock;
  static const _cacheFor = Duration(hours: 6);
  static const _batch = 200;

  final _reach = <String, ({ChatTarget? target, DateTime at})>{};
  final _conversations = <String, String>{};

  Future<bool> get signedIn async => await _auth.accessToken() != null;

  /// For each E.164 number: a [ChatTarget] when they can get a chat, null for
  /// a text. Answers are cached for a few hours. Offline → every number is
  /// a text (and nothing is cached).
  Future<Map<String, ChatTarget?>> reachability(Iterable<String> numbers) async {
    final token = await _auth.accessToken();
    final wanted = numbers.where((n) => n.startsWith('+')).toSet();
    final result = <String, ChatTarget?>{for (final n in numbers) n: null};
    if (token == null || wanted.isEmpty) return result;
    final now = _clock();
    final stale = <String>[];
    for (final n in wanted) {
      final hit = _reach[n];
      if (hit != null && now.difference(hit.at) < _cacheFor) {
        result[n] = hit.target;
      } else {
        stale.add(n);
      }
    }
    for (var i = 0; i < stale.length; i += _batch) {
      final chunk = stale.sublist(i, min(i + _batch, stale.length));
      final Map<String, dynamic> response;
      try {
        response = await _auth.api.post('/messages-plus/reachability', {'numbers': chunk}, token: token);
      } on ContactsPlusException {
        return result; // texts for the rest
      }
      for (final row in ((response['data'] as Map)['results'] as List).cast<Map>()) {
        final number = '${row['number']}';
        final target = row['channel'] == 'chat' && row['user_id'] != null
            ? ChatTarget(userId: '${row['user_id']}', displayName: row['display_name'] as String?)
            : null;
        _reach[number] = (target: target, at: now);
        result[number] = target;
      }
    }
    return result;
  }

  /// Sends [body] to [target] as a Contacts++ chat. [clientId] must be the
  /// same on every retry of the same message.
  Future<({ChatOutcome outcome, String? conversationId, String? error})> send(ChatTarget target, String body, {required String clientId}) async {
    final token = await _auth.accessToken();
    if (token == null) return (outcome: ChatOutcome.refused, conversationId: null, error: 'Not signed in to Contacts++.');
    String? conversation;
    try {
      conversation = _conversations[target.userId] ??= '${((await _auth.api.post('/conversations', {
            'type': 'direct',
            'participant_ids': [target.userId],
          }, token: token))['data'] as Map)['id']}';
    } on ContactsPlusException catch (e) {
      // Nothing was sent yet: a text can go instead.
      _forget(target.userId);
      return (outcome: ChatOutcome.refused, conversationId: null, error: e.message);
    }
    try {
      await _auth.api.post(
          '/conversations/$conversation/messages',
          {
            'client_id': clientId,
            'type': 'text',
            'body': body,
          },
          token: token);
      return (outcome: ChatOutcome.sent, conversationId: conversation, error: null);
    } on ContactsPlusException catch (e) {
      if (e.offline) return (outcome: ChatOutcome.uncertain, conversationId: conversation, error: e.message);
      _forget(target.userId);
      return (outcome: ChatOutcome.refused, conversationId: conversation, error: e.message);
    }
  }

  /// The member's Contacts++ chats, newest first.
  Future<List<ChatSummary>> conversations() async {
    final token = await _auth.accessToken();
    if (token == null) return const [];
    final data = (await _auth.api.get('/conversations', token: token))['data'] as Map;
    return [for (final c in (data['conversations'] as List).cast<Map>()) ChatSummary.fromJson(c)];
  }

  /// Messages in a chat: the latest page, or what changed since [cursor].
  /// Opening a chat marks what it shows as read.
  Future<({List<ChatMessage> messages, String? cursor, String? nextBefore})> messages(String conversationId,
      {String? changedSince, String? before}) async {
    final token = await _auth.accessToken();
    if (token == null) throw const ContactsPlusException('Sign in to Contacts++ to see this chat.', statusCode: 401);
    final query = Uri(queryParameters: {
      if (changedSince != null) 'changed_since': changedSince,
      if (before != null) 'before': before,
    }).query;
    final data = (await _auth.api.get('/conversations/$conversationId/messages${query.isEmpty ? '' : '?$query'}', token: token))['data'] as Map;
    return (
      messages: [for (final m in (data['messages'] as List).cast<Map>()) ChatMessage.fromJson(m)],
      cursor: data['sync_cursor'] as String?,
      nextBefore: data['next_before'] as String?,
    );
  }

  Future<void> markRead(String conversationId) async {
    final token = await _auth.accessToken();
    if (token == null) return;
    try {
      await _auth.api.put('/conversations/$conversationId/read', const {}, token: token);
    } on ContactsPlusException {
      // Unread counts catch up next time.
    }
  }

  /// Sends one message into an existing chat (the chat screen).
  Future<ChatMessage> sendInConversation(String conversationId, String body, {required String clientId}) async {
    final token = await _auth.accessToken();
    if (token == null) throw const ContactsPlusException('Sign in to Contacts++ to chat.', statusCode: 401);
    final data = (await _auth.api
        .post('/conversations/$conversationId/messages', {'client_id': clientId, 'type': 'text', 'body': body}, token: token))['data'] as Map;
    return ChatMessage.fromJson(data['message'] as Map);
  }

  /// The chat with [target], created when needed.
  Future<String> conversationWith(ChatTarget target) async {
    final token = await _auth.accessToken();
    if (token == null) throw const ContactsPlusException('Sign in to Contacts++ to chat.', statusCode: 401);
    return _conversations[target.userId] ??= '${((await _auth.api.post('/conversations', {
          'type': 'direct',
          'participant_ids': [target.userId],
        }, token: token))['data'] as Map)['id']}';
  }

  void _forget(String userId) {
    _conversations.remove(userId);
    _reach.removeWhere((_, v) => v.target?.userId == userId);
  }

  /// A random RFC 4122 version 4 id.
  static String newClientId([Random? random]) {
    final r = random ?? Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
