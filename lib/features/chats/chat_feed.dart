import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';

/// A chat message still on its way to Contacts++ (or refused, with Retry).
class PendingChat {
  PendingChat(this.clientId, this.body) : at = DateTime.now();
  final String clientId, body;
  final DateTime at;
  bool failed = false;
}

/// The messages of one Contacts++ chat, kept fresh while a screen shows them:
/// the latest page first, then only what changed every few seconds. Used by
/// the text conversation screen to show texts and chats in one timeline.
class ChatFeed extends ChangeNotifier {
  ChatFeed(this._chats, this.conversationId);

  final ContactsChatService _chats;
  final String conversationId;
  final _messages = <String, ChatMessage>{};
  final pending = <PendingChat>[];
  String? _cursor;
  Timer? _poll;
  bool loaded = false, _disposed = false;

  List<ChatMessage> get messages => _messages.values.where((m) => m.type != 'system').toList();

  Future<void> start() async {
    try {
      final page = await _chats.messages(conversationId);
      for (final m in page.messages) {
        _messages[m.id] = m;
      }
      _cursor = page.cursor;
    } on ContactsPlusException {
      // Shown without chats; the poll tries again.
    }
    loaded = true;
    _notify();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    unawaited(_chats.markRead(conversationId));
  }

  Future<void> _refresh() async {
    if (_cursor == null) {
      if (_messages.isEmpty) await _retryFirstPage();
      return;
    }
    try {
      final page = await _chats.messages(conversationId, changedSince: _cursor);
      _cursor = page.cursor ?? _cursor;
      if (page.messages.isEmpty) return;
      for (final m in page.messages) {
        _messages[m.id] = m;
        pending.removeWhere((o) => o.clientId == m.clientId);
      }
      _notify();
      unawaited(_chats.markRead(conversationId));
    } catch (_) {}
  }

  Future<void> _retryFirstPage() async {
    try {
      final page = await _chats.messages(conversationId);
      for (final m in page.messages) {
        _messages[m.id] = m;
      }
      _cursor = page.cursor;
      _notify();
    } catch (_) {}
  }

  /// Sends as a chat. Shown at once; stays with Retry when refused. The same
  /// client id on retry means Contacts++ never delivers it twice.
  Future<bool> send(String body, [PendingChat? retry]) async {
    final out = retry ?? PendingChat(ContactsChatService.newClientId(), body);
    out.failed = false;
    if (retry == null) pending.add(out);
    _notify();
    try {
      final sent = await _chats.sendInConversation(conversationId, out.body, clientId: out.clientId);
      pending.remove(out);
      _messages[sent.id] = sent;
      _notify();
      return true;
    } on ContactsPlusException {
      out.failed = true;
      _notify();
      return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }
}
