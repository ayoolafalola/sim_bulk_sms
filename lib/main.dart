import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'app/app.dart';
import 'app/providers.dart';
import 'app/startup_error_app.dart';
import 'data/database/app_database.dart';
import 'data/repositories/attempt_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // sqflite and SIM sending need a phone. lib/main_web.dart is a UI-only mock.
    runApp(const StartupErrorApp(
        title: 'Run this app on a phone',
        detail: 'SIM Bulk SMS stores data and sends SMS on Android or iOS. '
            'The browser cannot do either. Use `flutter run -d <your phone>`.'));
    return;
  }
  try {
    final db = await openAppDatabase(databaseFactory, p.join(await getDatabasesPath(), 'sim_bulk_sms.db'));
    // Anything that was in flight when the app last died has an uncertain
    // outcome: mark it `unknown` and pause the campaign. Never auto-resend.
    await AttemptRepository(db).recoverInterrupted();
    runApp(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const SimBulkSmsApp(),
    ));
  } catch (e, st) {
    debugPrint('Startup failed: $e\n$st');
    runApp(StartupErrorApp(title: 'The app could not start', detail: '$e'));
  }
}
