import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Guards the Google Play builds' manifests and identity (no device build needed).
void main() {
  final main = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final store = File('android/app/src/store/AndroidManifest.xml').readAsStringSync();
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();

  bool declares(String xml, String permission) =>
      RegExp('<uses-permission[^>]*android:name="android\\.permission\\.$permission"(?![^>]*tools:node="remove")')
          .hasMatch(xml);
  bool removes(String xml, String permission) =>
      RegExp('<uses-permission[^>]*android:name="android\\.permission\\.$permission"[^>]*tools:node="remove"')
          .hasMatch(xml);

  const restricted = [
    'SEND_SMS', 'READ_PHONE_STATE', 'FOREGROUND_SERVICE', 'FOREGROUND_SERVICE_SPECIAL_USE', 'WAKE_LOCK',
    'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
  ];

  test('full build declares what direct and background sending need', () {
    for (final p in restricted) {
      expect(declares(main, p), true, reason: '$p missing from the main manifest');
    }
    expect(main, contains('android:name=".SendService"'));
  });

  test('store build removes every Play-restricted permission and the send service', () {
    for (final p in restricted) {
      expect(removes(store, p), true, reason: 'store overlay must remove $p');
    }
    expect(RegExp(r'<service[^>]*android:name="\.SendService"[^>]*tools:node="remove"').hasMatch(store), true);
  });

  test('never declares SMS reading or the auto-granted exact-alarm permission', () {
    for (final p in ['READ_SMS', 'RECEIVE_SMS', 'USE_EXACT_ALARM', 'READ_CALL_LOG', 'WRITE_CONTACTS']) {
      expect(declares(main, p), false, reason: '$p must not be declared');
    }
  });

  test('release identity: package ID, target API 36, name', () {
    expect(gradle, contains('applicationId = "com.comeriver.simbulksms.app"'));
    expect(gradle, contains('targetSdk = 36'));
    expect(File('android/app/src/main/res/values/strings.xml').readAsStringSync(),
        contains('<string name="app_name">SIM-based Bulk SMS</string>'));
    expect(File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
        contains('PRODUCT_BUNDLE_IDENTIFIER = com.comeriver.simbulksms.app;'));
  });

  test('release signing never silently ships the debug key without a warning', () {
    expect(gradle, contains('key.properties'));
    expect(gradle, contains('Google Play will reject it'));
  });
}
