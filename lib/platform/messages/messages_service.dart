import 'dart:async';
import 'package:flutter/services.dart';

/// A conversation in the phone's message store.
class ConversationSummary {
  const ConversationSummary({
    required this.threadId, required this.addresses, this.name, required this.snippet, required this.date,
    this.unread = 0,
  });
  final int threadId;
  final List<String> addresses;
  /// Contact name(s) from the phone, if known.
  final String? name;
  final String snippet;
  final DateTime date;
  final int unread;
  String get title => (name?.trim().isNotEmpty ?? false) ? name! : addresses.join(', ');
}

enum StoredStatus { received, sending, sent, delivered, failed }

/// One text in a conversation.
class StoredMessage {
  const StoredMessage({required this.id, required this.address, required this.body, required this.date,
      required this.status, this.subId});
  final int id;
  /// SIM subscription it came in on / went out from (Android), if known.
  final int? subId;
  final String address, body;
  final DateTime date;
  final StoredStatus status;
  bool get incoming => status == StoredStatus.received;
}

/// What the app was opened for: a notification's conversation, or another app's "text this number".
class LaunchRequest {
  const LaunchRequest({this.threadId, this.address, this.body});
  final int? threadId;
  final String? address, body;
}

/// The phone's messages (Android, while this is the default messaging app).
abstract class MessagesService {
  Future<bool> isDefault();
  /// Shows Android's "set as default messaging app" prompt. True if it is now the default.
  Future<bool> requestDefault();
  Future<void> openDefaultAppsSettings();
  Future<List<ConversationSummary>> conversations();
  /// Oldest first.
  Future<List<StoredMessage>> messages(int threadId, {int limit = 200});
  Future<int> threadIdFor(String address);
  Future<void> markRead(int threadId);
  Future<void> markAllRead();
  /// Deletes from the phone's message store (only when the user asks).
  Future<bool> deleteMessage(int id);
  Future<bool> deleteThread(int threadId);
  /// Sends a personal text. False if it couldn't be handed to Android (e.g. not the default app).
  Future<bool> send(String address, String body, {int? subId});
  Future<LaunchRequest?> takeLaunch();
  /// Fires when messages change (a text arrived, a status updated) or the app was opened for something.
  Stream<String> get events;
}

/// Telephony provider row values (android.provider.Telephony.Sms).
StoredStatus storedStatusFrom(int type, int status) => switch (type) {
      1 => StoredStatus.received,
      2 => status == 0 ? StoredStatus.delivered : StoredStatus.sent, // STATUS_COMPLETE = 0
      5 => StoredStatus.failed,
      _ => StoredStatus.sending, // outbox / queued
    };

class NativeMessagesService implements MessagesService {
  static const _ch = MethodChannel('app.sim_bulk_sms/messages');
  static const _events = EventChannel('app.sim_bulk_sms/messages_events');
  Stream<String>? _stream;

  @override
  Future<bool> isDefault() async => await _ch.invokeMethod<bool>('isDefault') ?? false;
  @override
  Future<bool> requestDefault() async => await _ch.invokeMethod<bool>('requestDefault') ?? false;
  @override
  Future<void> openDefaultAppsSettings() => _ch.invokeMethod('openDefaultAppsSettings');

  @override
  Future<List<ConversationSummary>> conversations() async {
    final list = await _ch.invokeMethod<List<dynamic>>('conversations') ?? const [];
    return [
      for (final e in list.cast<Map<dynamic, dynamic>>())
        ConversationSummary(
          threadId: (e['threadId'] as num).toInt(),
          addresses: [for (final a in (e['addresses'] as List? ?? const [])) '$a'],
          name: e['name'] as String?,
          snippet: e['snippet'] as String? ?? '',
          date: DateTime.fromMillisecondsSinceEpoch((e['date'] as num).toInt()),
          unread: (e['unread'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<List<StoredMessage>> messages(int threadId, {int limit = 200}) async {
    final list = await _ch.invokeMethod<List<dynamic>>('messages', {'threadId': threadId, 'limit': limit}) ?? const [];
    return [
      for (final e in list.cast<Map<dynamic, dynamic>>().reversed)
        StoredMessage(
          id: (e['id'] as num).toInt(),
          address: e['address'] as String? ?? '',
          body: e['body'] as String? ?? '',
          date: DateTime.fromMillisecondsSinceEpoch((e['date'] as num).toInt()),
          status: storedStatusFrom((e['type'] as num).toInt(), (e['status'] as num? ?? -1).toInt()),
          subId: (e['subId'] as num?)?.toInt(),
        ),
    ];
  }

  @override
  Future<int> threadIdFor(String address) async =>
      (await _ch.invokeMethod<num>('threadIdFor', {'address': address}) ?? 0).toInt();
  @override
  Future<void> markRead(int threadId) => _ch.invokeMethod('markRead', {'threadId': threadId});
  @override
  Future<void> markAllRead() => _ch.invokeMethod('markAllRead');
  @override
  Future<bool> deleteMessage(int id) async => await _ch.invokeMethod<bool>('deleteMessage', {'id': id}) ?? false;
  @override
  Future<bool> deleteThread(int threadId) async =>
      await _ch.invokeMethod<bool>('deleteThread', {'threadId': threadId}) ?? false;
  @override
  Future<bool> send(String address, String body, {int? subId}) async =>
      await _ch.invokeMethod<bool>('send', {'address': address, 'body': body, 'subId': subId}) ?? false;

  @override
  Future<LaunchRequest?> takeLaunch() async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('takeLaunch');
    if (m == null) return null;
    return LaunchRequest(threadId: (m['threadId'] as num?)?.toInt(), address: m['address'] as String?,
        body: m['body'] as String?);
  }

  @override
  Stream<String> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((e) => (e as Map)['type'] as String? ?? 'changed')
      .asBroadcastStream();
}
