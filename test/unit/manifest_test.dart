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
    'REQUEST_IGNORE_BATTERY_OPTIMIZATIONS', 'READ_SMS', 'RECEIVE_SMS', 'RECEIVE_MMS', 'RECEIVE_WAP_PUSH', 'WRITE_SMS',
  ];
  // What Android requires before it offers an app as the default messaging app.
  const roleComponents = ['.SmsDeliverReceiver', '.MmsReceiver', '.QuickReplyService', '.ComposeAlias'];

  test('full build declares what direct and background sending need', () {
    for (final p in restricted) {
      expect(declares(main, p), true, reason: '$p missing from the main manifest');
    }
    expect(main, contains('android:name=".SendService"'));
    // Release builds only get INTERNET when the main manifest asks (campaign emails).
    expect(declares(main, 'INTERNET'), true);
  });

  test('full build has every default-messaging-app component, guarded as Android requires', () {
    for (final c in roleComponents) {
      expect(main, contains('android:name="$c"'), reason: '$c missing');
    }
    expect(main, contains('android:permission="android.permission.BROADCAST_SMS"'));
    expect(main, contains('android.provider.Telephony.SMS_DELIVER'));
    expect(main, contains('android:permission="android.permission.BROADCAST_WAP_PUSH"'));
    expect(main, contains('android:mimeType="application/vnd.wap.mms-message"'));
    expect(main, contains('android:permission="android.permission.SEND_RESPOND_VIA_MESSAGE"'));
    expect(main, contains('android.intent.action.RESPOND_VIA_MESSAGE'));
    expect(main, contains('android.intent.action.SENDTO'));
    for (final scheme in ['sms', 'smsto', 'mms', 'mmsto']) {
      expect(main, contains('android:scheme="$scheme"'));
    }
  });

  test('store build removes the default-messaging-app components', () {
    for (final c in roleComponents) {
      expect(RegExp('android:name="${RegExp.escape(c)}"[^>]*tools:node="remove"').hasMatch(store), true,
          reason: 'store overlay must remove $c');
    }
  });

  test('store build removes every Play-restricted permission and the send service', () {
    for (final p in restricted) {
      expect(removes(store, p), true, reason: 'store overlay must remove $p');
    }
    expect(RegExp(r'<service[^>]*android:name="\.SendService"[^>]*tools:node="remove"').hasMatch(store), true);
  });

  test('never declares call-log, contact-writing or the auto-granted exact-alarm permission', () {
    for (final p in ['USE_EXACT_ALARM', 'READ_CALL_LOG', 'WRITE_CONTACTS', 'READ_PHONE_NUMBERS']) {
      expect(declares(main, p), false, reason: '$p must not be declared');
    }
  });

  test('release identity: package ID, target API 36, name', () {
    expect(gradle, contains('applicationId = "com.comeriver.messages"'));
    expect(gradle, contains('targetSdk = 36'));
    expect(File('android/app/src/main/res/values/strings.xml').readAsStringSync(),
        contains('<string name="app_name">Comeriver Messages</string>'));
    expect(File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync(),
        contains('PRODUCT_BUNDLE_IDENTIFIER = com.comeriver.messages;'));
  });

  test('release signing never silently ships the debug key without a warning', () {
    expect(gradle, contains('key.properties'));
    expect(gradle, contains('Google Play will reject it'));
  });
}
