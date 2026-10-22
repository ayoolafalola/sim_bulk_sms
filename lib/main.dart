import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'app/app.dart';
import 'app/providers.dart';
import 'app/startup_error_app.dart';
import 'data/database/app_database.dart';
import 'app/settings_providers.dart';
import 'data/repositories/attempt_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'features/pro/pro_controller.dart';
import 'platform/background/background_send_service.dart';
import 'platform/billing/store_billing_service.dart';
import 'app/app_info.dart';

// Keeps the background service's Dart entry point compiled into the app.
export 'background/background_main.dart' show backgroundMain;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // sqflite and SIM sending need a phone. lib/main_web.dart is a UI-only mock.
    runApp(const StartupErrorApp(
        title: 'Run this app on a phone',
        detail: '$appName stores data and sends SMS on Android or iOS. '
            'The browser cannot do either. Use `flutter run -d <your phone>`.'));
    return;
  }
  try {
    final db = await openAppDatabase(databaseFactory, p.join(await getDatabasesPath(), 'sim_bulk_sms.db'));
    // Anything that was in flight when the app last died has an uncertain
    // outcome: mark it `unknown` and pause the campaign. Never auto-resend.
    // Skipped while the Android send service is running: it owns those sends.
    if (!await _sendServiceRunning()) await AttemptRepository(db).recoverInterrupted();
    final settings = await SettingsRepository(db).load();
    runApp(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        defaultRegionProvider.overrideWith((ref) => settings.defaultRegion),
        if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
          billingServiceProvider.overrideWithValue(StoreBillingService()),
      ],
      child: const SimBulkSmsApp(),
    ));
  } catch (e, st) {
    debugPrint('Startup failed: $e\n$st');
    runApp(StartupErrorApp(title: 'The app could not start', detail: '$e'));
  }
}

Future<bool> _sendServiceRunning() async {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return (await NativeBackgroundSendService().status()).serviceRunning;
  } catch (_) {
    return false;
  }
}
