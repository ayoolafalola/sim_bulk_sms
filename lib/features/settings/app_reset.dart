import 'package:sqflite/sqflite.dart';

/// "Reset app": empties every table of the app's own database, as if just installed. The phone's own
/// data is untouched: texts in its message store and its Contacts app (contacts sync can bring them back).
/// A Pro subscription lives with Google Play / the App Store and is picked up again on the next check.
Future<void> resetAppData(Database db) async {
  final tables = [
    for (final r in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'android_metadata'"))
      r['name'] as String,
  ];
  // Foreign keys off while emptying, so the order of the tables doesn't matter (can't change inside a transaction).
  await db.execute('PRAGMA foreign_keys = OFF');
  try {
    await db.transaction((txn) async {
      for (final t in tables) {
        await txn.delete(t);
      }
      final seq = await txn.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'");
      if (seq.isNotEmpty) await txn.delete('sqlite_sequence'); // ids start again from 1
    });
  } finally {
    await db.execute('PRAGMA foreign_keys = ON');
  }
}
