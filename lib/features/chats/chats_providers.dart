import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../account/account_controller.dart';

/// Contacts++ chats for the Messages tab. Local-first: the last list shows
/// at once (from the phone), then refreshes in the background.
final chatsProvider = AsyncNotifierProvider<ChatsController, List<ChatSummary>>(ChatsController.new);

class ChatsController extends AsyncNotifier<List<ChatSummary>> {
  static const _cacheKey = 'cpp_chats_cache';
  Timer? _poll;

  @override
  Future<List<ChatSummary>> build() async {
    final account = await ref.watch(accountProvider.future);
    _poll?.cancel();
    if (account == null) return const [];
    ref.onDispose(() => _poll?.cancel());
    final cached = await _readCache();
    // Refresh after the cached list is on screen, then every 30 s while shown.
    Future.microtask(refresh);
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    return cached;
  }

  Future<void> refresh() async {
    try {
      final fresh = await ref.read(contactsChatServiceProvider).conversations();
      state = AsyncData(fresh);
      await _writeCache(fresh);
    } catch (_) {
      // Keep what is shown; the next refresh tries again.
    }
  }

  /// Opening a chat clears its unread badge at once.
  void markOpened(String id) {
    final list = state.valueOrNull;
    if (list == null) return;
    state = AsyncData([
      for (final c in list)
        c.id == id
            ? ChatSummary(id: c.id, title: c.title, otherUserId: c.otherUserId, lastMessage: c.lastMessage,
                lastMessageAt: c.lastMessageAt, lastMessageIsMine: c.lastMessageIsMine)
            : c,
    ]);
  }

  Future<List<ChatSummary>> _readCache() async {
    try {
      final rows = await ref.read(databaseProvider).query('app_settings', where: 'key = ?', whereArgs: [_cacheKey]);
      final raw = rows.firstOrNull?['value'] as String?;
      if (raw == null) return const [];
      return [for (final c in (jsonDecode(raw) as List).cast<Map>()) ChatSummary.fromJson(c)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeCache(List<ChatSummary> chats) async {
    await ref.read(databaseProvider).rawInsert('INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)',
        [_cacheKey, jsonEncode([for (final c in chats.take(100)) c.toJson()])]);
  }
}

/// Unread Contacts++ chats, for the Messages tab badge.
final unreadChatsProvider = Provider<int>(
    (ref) => ref.watch(chatsProvider).valueOrNull?.fold<int>(0, (n, c) => n + c.unread) ?? 0);
