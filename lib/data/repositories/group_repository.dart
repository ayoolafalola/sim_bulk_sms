import 'package:sqflite/sqflite.dart';
import '../../domain/models/contact.dart';
import 'contact_repository.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

class GroupSummary {
  const GroupSummary(this.id, this.name, this.memberCount);
  final int id, memberCount;
  final String name;
}

class GroupRepository {
  GroupRepository(this._db);
  final Database _db;

  Future<int> create(String name) async {
    final now = _now();
    return _db.insert('recipient_groups', {'name': name.trim(), 'created_at': now, 'updated_at': now});
  }

  Future<void> rename(int id, String name) => _db.update('recipient_groups',
      {'name': name.trim(), 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) => _db.delete('recipient_groups', where: 'id = ?', whereArgs: [id]);

  Future<int> count() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM recipient_groups')) ?? 0;

  Future<List<GroupSummary>> list() async {
    final rows = await _db.rawQuery('''
      SELECT g.id, g.name, COUNT(gc.contact_id) AS n
      FROM recipient_groups g LEFT JOIN group_contacts gc ON gc.group_id = g.id
      GROUP BY g.id ORDER BY g.name COLLATE NOCASE''');
    return rows.map((r) => GroupSummary(r['id'] as int, r['name'] as String, r['n'] as int)).toList();
  }

  /// Idempotent: adding an existing member is a no-op.
  Future<void> addContacts(int groupId, Iterable<int> contactIds) => _db.transaction((txn) async {
        final b = txn.batch();
        for (final id in contactIds) {
          b.insert('group_contacts', {'group_id': groupId, 'contact_id': id},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await b.commit(noResult: true);
      });

  Future<void> removeContact(int groupId, int contactId) => _db.delete('group_contacts',
      where: 'group_id = ? AND contact_id = ?', whereArgs: [groupId, contactId]);

  Future<List<Contact>> members(int groupId) async {
    final rows = await _db.rawQuery('''
      SELECT c.* FROM contacts c JOIN group_contacts gc ON gc.contact_id = c.id
      WHERE gc.group_id = ? ORDER BY c.name COLLATE NOCASE''', [groupId]);
    return rows.map((r) => Contact(
        id: r['id'] as int, name: r['name'] as String, phoneRaw: r['phone_raw'] as String,
        phoneNormalized: r['phone_normalized'] as String?, email: r['email'] as String?,
        consent: consentFromDb(r['consent_status'] as String))).toList();
  }
}
