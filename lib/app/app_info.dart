import 'package:flutter/foundation.dart';

/// Shown on the home screen, in the app and in notifications.
const appName = 'Messages++';
/// The name in the stores.
const appFullName = 'Messages++ by Comeriver';
/// Version name, as in pubspec.yaml (a test checks they match).
const appVersion = '1.0.1';

/// The store this build is sold through, for user-facing text ("cancel in Google Play").
/// Each build names only its own platform's store.
String get storeName => defaultTargetPlatform == TargetPlatform.iOS ? 'the App Store' : 'Google Play';

/// Links shown in Settings › About.
class AppLinks {
  static const website = 'https://messages.comeriver.com';
  static const privacy = 'https://messages.comeriver.com/privacy';
  static const terms = 'https://messages.comeriver.com/terms';
  static const developer = 'https://comeriver.com';
  static const supportEmail = 'messages@comeriver.com';
}

/// The Google Play "store" build: no SMS-sending permission and no background
/// send service; messages go through the Messages app and schedules remind
/// you. Set with `--dart-define=STORE_BUILD=true` (Gradle reads the same flag
/// and removes those permissions from the manifest). See docs/RELEASE.md.
const isStoreBuild = bool.fromEnvironment('STORE_BUILD');
