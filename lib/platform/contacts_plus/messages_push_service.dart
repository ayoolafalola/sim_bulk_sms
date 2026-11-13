import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'contacts_plus_api.dart';
import 'contacts_plus_auth.dart';

/// Messages++ has its own Firebase app (like Events++); supply it at build
/// time. Without it, chats and web-queued texts still arrive whenever the
/// app is open (it checks on open and every few seconds while a chat is open).
abstract final class MessagesFirebaseConfig {
  // Android and iOS are separate Firebase apps in the same project; the
  // plain values remain a fallback for older config files.
  static const _apiKey = String.fromEnvironment('MESSAGES_FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('MESSAGES_FIREBASE_APP_ID');
  static const _androidApiKey = String.fromEnvironment('MESSAGES_FIREBASE_ANDROID_API_KEY');
  static const _androidAppId = String.fromEnvironment('MESSAGES_FIREBASE_ANDROID_APP_ID');
  static const _iosApiKey = String.fromEnvironment('MESSAGES_FIREBASE_IOS_API_KEY');
  static const _iosAppId = String.fromEnvironment('MESSAGES_FIREBASE_IOS_APP_ID');
  static bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;
  static String get apiKey => _pick(_ios ? _iosApiKey : _androidApiKey, _apiKey);
  static String get appId => _pick(_ios ? _iosAppId : _androidAppId, _appId);
  static String _pick(String platform, String fallback) => platform.isNotEmpty ? platform : fallback;
  static const senderId = String.fromEnvironment('MESSAGES_FIREBASE_MESSAGING_SENDER_ID');
  static const projectId = String.fromEnvironment('MESSAGES_FIREBASE_PROJECT_ID');
  static const bucket = String.fromEnvironment('MESSAGES_FIREBASE_STORAGE_BUCKET');

  static bool get configured => apiKey.isNotEmpty && appId.isNotEmpty && senderId.isNotEmpty && projectId.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: senderId,
        projectId: projectId,
        storageBucket: bucket.isEmpty ? null : bucket,
      );
}

@pragma('vm:entry-point')
Future<void> messagesPushBackgroundHandler(RemoteMessage message) async {
  if (!MessagesFirebaseConfig.configured) return;
  if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: MessagesFirebaseConfig.options);
}

/// Contacts++ push for Messages++: registers this phone (scoped to the
/// `messages-plus` client, so Contacts++ and Messages++ tokens never mix),
/// opens notification taps at the exact chat, and passes data pushes on.
class MessagesPushService {
  MessagesPushService._();
  static final instance = MessagesPushService._();

  /// `messagesplus://` links from tapped notifications.
  final links = StreamController<Uri>.broadcast();

  /// Pushes that arrive while the app is open (refresh chats, run the relay…).
  final foreground = StreamController<Map<String, dynamic>>.broadcast();

  StreamSubscription<String>? _tokenRefresh;
  String? _token;
  bool _initialized = false;

  bool get configured => MessagesFirebaseConfig.configured;

  /// Runs in its own isolate when a push arrives with the app closed. Must be
  /// a top-level function marked `@pragma('vm:entry-point')`. Set by main().
  static Future<void> Function(RemoteMessage message) backgroundHandler = messagesPushBackgroundHandler;

  /// Safe to call on every start and after sign-in. Never asks for
  /// permission (see [requestPermission]).
  Future<bool> activate(ContactsPlusAuth auth) async {
    if (!configured || await auth.accessToken() == null) return false;
    try {
      if (!_initialized) {
        if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: MessagesFirebaseConfig.options);
        FirebaseMessaging.onBackgroundMessage(backgroundHandler);
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
        FirebaseMessaging.onMessageOpenedApp.listen(_open);
        FirebaseMessaging.onMessage.listen((m) => foreground.add(m.data));
        final initial = await FirebaseMessaging.instance.getInitialMessage();
        if (initial != null) _open(initial);
        _initialized = true;
      }
      // ignore: deprecated_member_use
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return false;
      _token = token;
      await _register(auth, token);
      // ignore: deprecated_member_use
      _tokenRefresh ??= FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        _token = t;
        _register(auth, t);
      });
      return true;
    } catch (e) {
      debugPrint('Messages++ push not available: $e');
      return false;
    }
  }

  Future<bool> requestPermission(ContactsPlusAuth auth) async {
    if (!configured) return false;
    await activate(auth);
    final s = await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
    await activate(auth);
    return s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
  }

  /// On sign-out: this phone stops getting this account's chats.
  Future<void> deactivate(ContactsPlusAuth auth) async {
    final token = _token, access = await auth.accessToken();
    if (token != null && access != null) {
      try {
        await auth.api.delete('/notifications/devices', token: access, body: {'token': token});
      } on ContactsPlusException {
        // The server drops tokens that stop working.
      }
    }
    await _tokenRefresh?.cancel();
    _tokenRefresh = null;
    _token = null;
  }

  Future<void> _register(ContactsPlusAuth auth, String token) async {
    final access = await auth.accessToken();
    if (access == null) return;
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    try {
      await auth.api.put(
          '/notifications/devices',
          {
            'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
            'token': token,
            'notifications_allowed': settings.authorizationStatus == AuthorizationStatus.authorized ||
                settings.authorizationStatus == AuthorizationStatus.provisional,
          },
          token: access);
    } on ContactsPlusException {
      // Registered again on the next start.
    }
  }

  void _open(RemoteMessage message) {
    final uri = Uri.tryParse('${message.data['deep_link'] ?? ''}');
    if (uri != null && uri.scheme == 'messagesplus') links.add(uri);
  }
}
