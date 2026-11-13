import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../../platform/contacts_plus/contacts_plus_auth.dart';
import '../../platform/contacts_plus/messages_push_service.dart';

/// One Contacts++ session for the whole app. Overridden in tests.
final contactsPlusAuthProvider = Provider<ContactsPlusAuth>((ref) => ContactsPlusAuth());

/// The signed-in Contacts++ member, or null. Messages++ keeps working fully
/// without an account; signing in adds chats, backup and the web app.
final accountProvider = AsyncNotifierProvider<AccountController, ContactsPlusAccount?>(AccountController.new);

class AccountController extends AsyncNotifier<ContactsPlusAccount?> {
  StreamSubscription<ContactsPlusAccount?>? _changes;

  ContactsPlusAuth get _auth => ref.read(contactsPlusAuthProvider);

  @override
  Future<ContactsPlusAccount?> build() async {
    _changes?.cancel();
    _changes = _auth.changes.listen((account) => state = AsyncData(account));
    ref.onDispose(() => _changes?.cancel());
    return _auth.account();
  }

  /// Opens Contacts++ (the app if installed, else the website) to approve.
  Future<void> signIn() async {
    final uri = await _auth.beginSignIn();
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const ContactsPlusException('Contacts++ couldn’t be opened. Check your connection and try again.');
    }
  }

  /// Finishes sign-in from `messagesplus://auth/callback?...`.
  Future<ContactsPlusAccount> completeSignIn(Uri callback) async {
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    final account = await _auth.completeSignIn(callback, platform: platform);
    state = AsyncData(account);
    return account;
  }

  Future<void> signOut() async {
    // Optimistic: the phone is signed out at once; the server is told after.
    final previous = state;
    state = const AsyncData(null);
    try {
      await MessagesPushService.instance.deactivate(_auth);
      await _auth.signOut();
    } catch (_) {
      state = previous;
      rethrow;
    }
  }
}

/// The signed-in member's Contacts++ profile photo (JPEG/PNG bytes), or null
/// when they have none or are signed out. The last photo shows at once from
/// the phone; a fresh one is fetched behind it.
final profilePhotoProvider = AsyncNotifierProvider<ProfilePhotoController, Uint8List?>(ProfilePhotoController.new);

class ProfilePhotoController extends AsyncNotifier<Uint8List?> {
  static const _cacheKey = 'cpp_profile_photo';

  @override
  Future<Uint8List?> build() async {
    final account = await ref.watch(accountProvider.future);
    if (account == null) {
      await _write(null);
      return null;
    }
    final cached = await _read(account.userId);
    Future.microtask(() => _refresh(account.userId));
    return cached;
  }

  Future<void> _refresh(String userId) async {
    final auth = ref.read(contactsPlusAuthProvider);
    try {
      final token = await auth.accessToken();
      if (token == null) return;
      final user = ((await auth.api.get('/connected-app/me', token: token))['data'] as Map)['user'] as Map;
      final raw = user['profile_photo'] as String?;
      final bytes = raw == null || raw.isEmpty ? null : base64Decode(raw);
      await _write(raw == null ? null : '$userId:$raw');
      state = AsyncData(bytes);
    } catch (_) {
      // Offline or refused: keep the photo shown.
    }
  }

  Future<Uint8List?> _read(String userId) async {
    try {
      final rows = await ref.read(databaseProvider).query('app_settings', where: 'key = ?', whereArgs: [_cacheKey]);
      final raw = rows.firstOrNull?['value'] as String?;
      if (raw == null || !raw.startsWith('$userId:')) return null;
      return base64Decode(raw.substring(userId.length + 1));
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String? value) async {
    try {
      final db = ref.read(databaseProvider);
      if (value == null) {
        await db.delete('app_settings', where: 'key = ?', whereArgs: [_cacheKey]);
      } else {
        await db.rawInsert('INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)', [_cacheKey, value]);
      }
    } catch (_) {}
  }
}
