import 'package:sqflite/sqflite.dart';
import 'schema_v1.dart';

const currentSchemaVersion = 1;

/// Opens the app database with foreign keys enforced. Pass a [DatabaseFactory]
/// so tests can use an in-memory sqflite_common_ffi database.
Future<Database> openAppDatabase(DatabaseFactory factory, String path) {
  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: currentSchemaVersion,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, v) async {
        final batch = db.batch();
        for (final s in schemaV1) { batch.execute(s); }
        await batch.commit(noResult: true);
      },
      // Future migrations: onUpgrade: (db, from, to) { if (from < 2) {...} }
    ),
  );
}
