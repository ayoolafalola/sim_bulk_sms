import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'contacts_plus_api.dart';
import 'contacts_plus_config.dart';

/// The Contacts++ member signed in to Messages++.
@immutable
class ContactsPlusAccount {
  const ContactsPlusAccount({required this.userId, required this.displayName, this.username});
  final String userId;
  final String displayName;
  final String? username;

  Map<String, dynamic> toJson() => {'id': userId, 'display_name': displayName, 'username': username};

  static ContactsPlusAccount fromJson(Map<dynamic, dynamic> json) => ContactsPlusAccount(
        userId: '${json['id']}',
        displayName: '${json['display_name'] ?? json['username'] ?? 'You'}',
        username: json['username'] as String?,
      );
}

/// Sign-in with Contacts++ (PKCE connected-app flow).
///
/// Messages++ never sees the Contacts++ password or the Contacts++ app's own
/// session: Contacts++ (app or website) approves the request and returns a
/// one-time code to `messagesplus://auth/callback`, which is exchanged here,
/// with the PKCE verifier, for a separate, scoped session. Tokens live in the
/// Keychain/Keystore under Messages++'s own keys.
class ContactsPlusAuth {
  ContactsPlusAuth({FlutterSecureStorage? storage, ContactsPlusApi? api})
      : _storage = storage ?? const FlutterSecureStorage(),
        api = api ?? ContactsPlusApi() {
    this.api.tokenRefresher = refresh;
    this.api.onSessionRejected = clearSession;
  }

  static const _accessKey = 'cpp_access_token';
  static const _refreshKey = 'cpp_refresh_token';
  static const _accountKey = 'cpp_account';
  static const _pendingStateKey = 'cpp_pending_state';
  static const _pendingVerifierKey = 'cpp_pending_verifier';

  final FlutterSecureStorage _storage;
  final ContactsPlusApi api;
  final _changes = StreamController<ContactsPlusAccount?>.broadcast();
  Completer<String?>? _refreshing;

  /// Emits the account after sign-in and null after sign-out.
  Stream<ContactsPlusAccount?> get changes => _changes.stream;

  Future<String?> accessToken() => _read(_accessKey);

  /// Secure storage, or null where it isn't available (tests, a locked keychain).
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<ContactsPlusAccount?> account() async {
    final raw = await _read(_accountKey);
    if (raw == null || await accessToken() == null) return null;
    try {
      return ContactsPlusAccount.fromJson(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  /// The Contacts++ address to open. With Contacts++ installed the phone opens
  /// the app's approval screen; otherwise the website signs the person in.
  Future<Uri> beginSignIn() async {
    final state = randomToken(32);
    final verifier = randomToken(64);
    await _storage.write(key: _pendingStateKey, value: state);
    await _storage.write(key: _pendingVerifierKey, value: verifier);
    return Uri.parse(ContactsPlusConfig.contactsWeb).replace(
      path: '/app-authorize',
      queryParameters: {
        'client_id': ContactsPlusConfig.clientId,
        'redirect_uri': ContactsPlusConfig.redirectUri,
        'code_challenge': pkceChallenge(verifier),
        'state': state,
        'scopes': ContactsPlusConfig.scopes.join(' '),
      },
    );
  }

  static bool isCallback(Uri uri) =>
      (uri.scheme == 'https' && uri.host == 'contacts.comeriver.com' && uri.path == '/messages/auth/callback') ||
      (uri.scheme == ContactsPlusConfig.callbackScheme && uri.host == 'auth' && uri.path == '/callback');

  Future<ContactsPlusAccount> completeSignIn(Uri callback, {required String platform}) async {
    if (!isCallback(callback)) {
      throw const ContactsPlusException('This sign-in link is not for Messages++.');
    }
    if (callback.queryParameters['error'] == 'access_denied') {
      await _clearPending();
      throw const ContactsPlusException('Sign-in was cancelled. Messages++ works without an account too.');
    }
    final code = callback.queryParameters['code'];
    final state = callback.queryParameters['state'];
    final expectedState = await _storage.read(key: _pendingStateKey);
    final verifier = await _storage.read(key: _pendingVerifierKey);
    if (code == null || state == null || expectedState == null || verifier == null || !constantTimeEquals(state, expectedState)) {
      throw const ContactsPlusException('This sign-in request is invalid or has expired. Try again.');
    }
    final response = await api.post('/auth/connected-app/token', {
      'grant_type': 'authorization_code',
      'client_id': ContactsPlusConfig.clientId,
      'redirect_uri': ContactsPlusConfig.redirectUri,
      'code': code,
      'code_verifier': verifier,
      'device_name': 'Messages++ on ${platform == 'ios' ? 'iPhone' : 'Android'}',
      'platform': platform,
    });
    final data = response['data'] as Map;
    await _storeTokens(data['tokens'] as Map);
    final account = ContactsPlusAccount.fromJson(data['user'] as Map);
    await _storage.write(key: _accountKey, value: jsonEncode(account.toJson()));
    await _clearPending();
    _changes.add(account);
    return account;
  }

  /// A fresh access token after [failedToken] was refused, or null when the
  /// session has ended. Concurrent callers share one refresh.
  Future<String?> refresh(String failedToken) async {
    final current = await accessToken();
    if (current != null && current != failedToken) return current;
    if (_refreshing != null) return _refreshing!.future;
    final completer = Completer<String?>();
    _refreshing = completer;
    try {
      final refreshToken = await _storage.read(key: _refreshKey);
      if (refreshToken == null) {
        completer.complete(null);
        return null;
      }
      final response = await api.post('/auth/refresh', {'refresh_token': refreshToken});
      final tokens = (response['data'] as Map)['tokens'] as Map;
      await _storeTokens(tokens);
      final renewed = '${tokens['access_token']}';
      completer.complete(renewed);
      return renewed;
    } on ContactsPlusException catch (e) {
      // Offline: keep the session and try again later. Refused: signed out.
      if (!e.offline) await clearSession();
      completer.complete(null);
      return null;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> signOut() async {
    final token = await accessToken();
    if (token != null) {
      try {
        await api.post('/auth/logout', const {}, token: token);
      } catch (_) {
        // Signing out on the phone must always work.
      }
    }
    await clearSession();
  }

  Future<void> clearSession() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
    await _storage.delete(key: _accountKey);
    _changes.add(null);
  }

  Future<void> _storeTokens(Map<dynamic, dynamic> tokens) async {
    await _storage.write(key: _accessKey, value: '${tokens['access_token']}');
    await _storage.write(key: _refreshKey, value: '${tokens['refresh_token']}');
  }

  Future<void> _clearPending() async {
    await _storage.delete(key: _pendingStateKey);
    await _storage.delete(key: _pendingVerifierKey);
  }

  @visibleForTesting
  static String randomToken(int byteLength) {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(byteLength, (_) => random.nextInt(256))).replaceAll('=', '');
  }

  @visibleForTesting
  static String pkceChallenge(String verifier) => base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');

  @visibleForTesting
  static bool constantTimeEquals(String left, String right) {
    final a = utf8.encode(left), b = utf8.encode(right);
    var difference = a.length ^ b.length;
    for (var i = 0; i < max(a.length, b.length); i++) {
      difference |= (i < a.length ? a[i] : 0) ^ (i < b.length ? b[i] : 0);
    }
    return difference == 0;
  }
}

/// Values every campaign message can use while signed in:
/// {invite_link} is the member's Contacts++ link (their profile when they
/// have a username), so a group text can invite people to Contacts++.
Future<Map<String, String>> contactsPlusSharedValues(ContactsPlusAuth auth) async {
  final account = await auth.account();
  if (account == null) return const {};
  final username = account.username;
  return {
    'invite_link': username == null || username.isEmpty ? ContactsPlusConfig.contactsWeb : '${ContactsPlusConfig.contactsWeb}/@$username',
  };
}
