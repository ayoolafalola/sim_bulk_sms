import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'app/app.dart';
import 'app/providers.dart';
import 'data/database/app_database.dart';
import 'data/repositories/attempt_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openAppDatabase(databaseFactory, p.join(await getDatabasesPath(), 'sim_bulk_sms.db'));
  // Anything that was in flight when the app last died has an uncertain
  // outcome: mark it `unknown` and pause the campaign. Never auto-resend.
  await AttemptRepository(db).recoverInterrupted();
  runApp(ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: const SimBulkSmsApp(),
  ));
}
