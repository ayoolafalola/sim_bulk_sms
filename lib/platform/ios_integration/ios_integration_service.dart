import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// iPhone and iPad: links left by Siri/Spotlight shortcuts, text shared
/// through the Share Extension, and conversations donated so people appear
/// at the top of the share sheet. Every call is a no-op elsewhere.
class IosIntegrationService {
  static const _ch = MethodChannel('app.sim_bulk_sms/ios_integration');
  static bool get _ios => Platform.isIOS;

  /// A `messagesplus://` link from an App Shortcut, read once.
  Future<Uri?> takePendingLink() async {
    if (!_ios) return null;
    try {
      final link = await _ch.invokeMethod<String>('takePendingLink');
      return link == null ? null : Uri.tryParse(link);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// What the Share Extension saved: the text, and the conversation picked
  /// at the top of the share sheet (`chat:<id>`), if any. Read once.
  Future<({String text, String? conversation})?> takeIncomingShare() async {
    if (!_ios) return null;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('takeIncomingShare');
      if (m == null) return null;
      return (text: '${m['text'] ?? ''}', conversation: m['conversation'] as String?);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Tells iOS this conversation was used, for share-sheet suggestions.
  Future<void> donateConversation({required String id, required String name, String? phone}) async {
    if (!_ios) return;
    try {
      await _ch.invokeMethod('donateConversation', {'id': id, 'name': name, 'handle': phone});
    } on PlatformException {
      // Suggestions are a nicety.
    } on MissingPluginException {
      // Tests and older builds.
    }
  }
}
