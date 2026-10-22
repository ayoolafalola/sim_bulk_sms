import 'package:sqflite/sqflite.dart';
import 'schema_v1.dart';
import 'schema_v2.dart';
import 'schema_v3.dart';
import 'schema_v5.dart';
import 'schema_v6.dart';
import 'schema_v7.dart';
import 'schema_v8.dart';

const currentSchemaVersion = 8; // v4 was never used

/// Opens the app database with foreign keys enforced. Pass a [DatabaseFactory]
/// so tests can use an in-memory sqflite_common_ffi database.
Future<Database> openAppDatabase(DatabaseFactory factory, String path) {
  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: currentSchemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        // The app screen and the background send service each hold a connection:
        // wait for a lock instead of failing with "database is locked".
        await db.rawQuery('PRAGMA busy_timeout = 5000');
      },
      onCreate: (db, v) async {
        final batch = db.batch();
        for (final s in [...schemaV1, ...schemaV2, ...schemaV3, ...schemaV5, ...schemaV6, ...schemaV7, ...schemaV8]) { batch.execute(s); }
        await batch.commit(noResult: true);
      },
      // Each step runs in sqflite's upgrade transaction: all or nothing.
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          for (final s in schemaV2) { await db.execute(s); }
        }
        if (from < 3) {
          for (final s in schemaV3) { await db.execute(s); }
        }
        if (from < 5) {
          for (final s in schemaV5) { await db.execute(s); }
        }
        if (from < 6) {
          for (final s in schemaV6) { await db.execute(s); }
        }
        if (from < 7) {
          for (final s in schemaV7) { await db.execute(s); }
        }
        if (from < 8) {
          for (final s in schemaV8) { await db.execute(s); }
        }
      },
    ),
  );
}
