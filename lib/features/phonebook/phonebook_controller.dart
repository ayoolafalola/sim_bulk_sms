import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/phonebook/phonebook_service.dart';
import '../account/account_controller.dart';

/// Android only; null elsewhere.
final phonebookServiceProvider = Provider<PhonebookService?>((ref) => Platform.isAndroid ? NativePhonebookService() : null);

/// Settings › "Show in my Contacts app" (off until turned on).
final phonebookEnabledProvider = FutureProvider<bool>((ref) async {
  ref.watch(dataVersionProvider);
  return ref.watch(settingsRepositoryProvider).flag('phonebook_on');
});

final phonebookControllerProvider = Provider((ref) => PhonebookController(ref));

/// Builds one card per phone contact: "Text" for each number, and "Chat" for
/// numbers whose owner can get a Contacts++ chat (when signed in).
Future<List<PhonebookCard>> phonebookCards(Database db, {ContactsChatService? chats, int chatCheckLimit = 2000}) async {
  final rows = await db.rawQuery('''
    SELECT c.phone_contact_id AS native_id, c.name, COALESCE(p.normalized, c.phone_normalized) AS phone
    FROM contacts c LEFT JOIN contact_phones p ON p.contact_id = c.id
    WHERE c.source = 'phone' AND c.phone_contact_id IS NOT NULL''');
  final byContact = <int, ({String name, Set<String> numbers})>{};
  for (final r in rows) {
    final phone = r['phone'] as String?;
    if (phone == null || !phone.startsWith('+')) continue;
    final id = r['native_id'] as int;
    byContact.putIfAbsent(id, () => (name: '${r['name']}', numbers: <String>{})).numbers.add(phone);
  }
  var chat = const <String, ChatTarget?>{};
  if (chats != null && await chats.signedIn) {
    final all = byContact.values.expand((c) => c.numbers).take(chatCheckLimit).toList();
    chat = await chats.reachability(all);
  }
  return [
    for (final e in byContact.entries)
      PhonebookCard(
        key: 'contact:${e.key}',
        name: e.value.name,
        numbers: e.value.numbers.toList()..sort(),
        chatNumbers: [for (final n in e.value.numbers) if (chat[n] != null) n]..sort(),
        nativeId: e.key,
      ),
  ];
}

class PhonebookController {
  PhonebookController(this._ref);
  final Ref _ref;
  bool _busy = false;

  PhonebookService? get _service => _ref.read(phonebookServiceProvider);

  /// Turns the Contacts-app actions on (asks for permission) or off (removes them all).
  Future<bool> setEnabled(bool on) async {
    final service = _service;
    if (service == null) return false;
    final settings = _ref.read(settingsRepositoryProvider);
    if (on && !await service.requestWrite()) return false;
    await settings.setFlag('phonebook_on', on);
    _ref.read(dataVersionProvider.notifier).state++;
    if (on) {
      await refresh();
    } else {
      await service.removeAll();
    }
    return true;
  }

  /// Rewrites changed records (after contacts sync, sign-in or sign-out).
  Future<void> refresh() async {
    final service = _service;
    if (service == null || _busy) return;
    if (!await _ref.read(settingsRepositoryProvider).flag('phonebook_on')) return;
    if (!await service.canWrite()) return;
    _busy = true;
    try {
      final signedIn = _ref.read(accountProvider).valueOrNull != null;
      final cards = await phonebookCards(_ref.read(databaseProvider),
          chats: signedIn ? _ref.read(contactsChatServiceProvider) : null);
      await service.synchronize(cards);
    } catch (_) {
      // Tried again on the next contacts sync.
    } finally {
      _busy = false;
    }
  }

  /// Recent conversations as people in the share sheet.
  Future<void> publishShareTargets() async {
    final service = _service;
    final messages = _ref.read(messagesServiceProvider);
    if (service == null || messages == null) return;
    try {
      if (!await messages.isDefault()) return;
      final recent = (await messages.conversations()).where((c) => c.addresses.length == 1).take(8);
      await service.publishShareTargets([for (final c in recent) (name: c.title, phone: c.addresses.first)]);
    } catch (_) {}
  }
}
