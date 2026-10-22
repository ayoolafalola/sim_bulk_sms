import 'package:sqflite/sqflite.dart';
import '../../domain/models/contact.dart';
import '../../domain/models/statuses.dart';
import '../importers/contact_import_planner.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

String consentToDb(ConsentStatus s) => switch (s) {
      ConsentStatus.unknown => 'unknown', ConsentStatus.optedIn => 'opted_in', ConsentStatus.optedOut => 'opted_out' };
ConsentStatus consentFromDb(String s) => switch (s) {
      'opted_in' => ConsentStatus.optedIn, 'opted_out' => ConsentStatus.optedOut, _ => ConsentStatus.unknown };

/// Result of [ContactRepository.commitImportToGroup].
class ImportResult {
  const ImportResult({required this.added, this.groupId, this.inGroup = 0});
  /// New contacts created.
  final int added;
  /// The group everyone was added to (new or existing), if any.
  final int? groupId;
  /// People from the file now in that group (new and existing contacts).
  final int inGroup;
}

/// Result of [ContactRepository.upsertByPhone].
class UpsertResult {
  const UpsertResult({required this.ids, required this.added, required this.existing});
  /// App contact ids for every entry, in input order, de-duplicated.
  final List<int> ids;
  final int added, existing;
}

/// A contacts row (any query selecting `contacts.*`) as a [Contact].
Contact contactFromRow(Map<String, Object?> r) => Contact(
      id: r['id'] as int, name: r['name'] as String, phoneRaw: r['phone_raw'] as String,
      phoneNormalized: r['phone_normalized'] as String?, email: r['email'] as String?,
      consent: consentFromDb(r['consent_status'] as String),
      source: r['source'] == 'phone' ? ContactSource.phone : ContactSource.app,
      lookupKey: r['lookup_key'] as String?, phoneContactId: r['phone_contact_id'] as int?,
      givenName: r['given_name'] as String?, familyName: r['family_name'] as String?,
      organization: r['organization'] as String?, jobTitle: r['job_title'] as String?,
      birthday: r['birthday'] as String?, address: r['address'] as String?, note: r['note'] as String?,
    );

class ContactRepository {
  ContactRepository(this._db);
  final Database _db;

  Contact _fromRow(Map<String, Object?> r) => contactFromRow(r);

  Future<int> add(Contact c) async {
    final now = _now();
    // Phone contacts may share numbers, so uniqueness is checked here for manual adds.
    if (c.phoneNormalized != null &&
        (await _db.query('contacts', columns: ['id'], where: 'phone_normalized = ?', whereArgs: [c.phoneNormalized]))
            .isNotEmpty) {
      throw DuplicateContactException(c.phoneNormalized!);
    }
    try {
      return await _db.insert('contacts', {
        'name': c.name, 'phone_raw': c.phoneRaw, 'phone_normalized': c.phoneNormalized, 'email': c.email,
        'consent_status': consentToDb(c.consent),
        'consent_updated_at': c.consent == ConsentStatus.unknown ? null : now,
        'created_at': now, 'updated_at': now,
      });
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) throw DuplicateContactException(c.phoneNormalized ?? '');
      rethrow;
    }
  }

  Future<void> update(Contact c) async {
    try {
      await _db.update('contacts', {
        'name': c.name, 'phone_raw': c.phoneRaw, 'phone_normalized': c.phoneNormalized,
        'email': c.email, 'birthday': c.birthday, 'organization': c.organization, 'updated_at': _now(),
      }, where: 'id = ?', whereArgs: [c.id]);
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) throw DuplicateContactException(c.phoneNormalized ?? '');
      rethrow;
    }
  }

  Future<void> setConsent(int id, ConsentStatus s) => _db.update('contacts',
      {'consent_status': consentToDb(s), 'consent_updated_at': _now(), 'updated_at': _now()},
      where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) => _db.delete('contacts', where: 'id = ?', whereArgs: [id]);

  Future<int> count() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM contacts')) ?? 0;

  Future<List<Contact>> search([String query = '']) async {
    final q = query.trim();
    final rows = q.isEmpty
        ? await _db.query('contacts', orderBy: 'name COLLATE NOCASE')
        : await _db.query('contacts',
            where: 'name LIKE ? OR phone_raw LIKE ? OR phone_normalized LIKE ? OR email LIKE ? OR organization LIKE ?',
            whereArgs: ['%$q%', '%$q%', '%$q%', '%$q%', '%$q%'], orderBy: 'name COLLATE NOCASE');
    return rows.map(_fromRow).toList();
  }

  Future<Contact?> get(int id) async {
    final rows = await _db.query('contacts', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Every number, email and date of a contact (an app-only contact has just its own).
  Future<ContactDetails?> details(int id) async {
    final rows = await _db.query('contacts', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final c = _fromRow(rows.first);
    var phones = [
      for (final r in await _db.query('contact_phones', where: 'contact_id = ?', whereArgs: [id], orderBy: 'id'))
        ContactValue(value: r['raw'] as String, normalized: r['normalized'] as String?, label: r['label'] as String?,
            isDefault: r['is_default'] == 1),
    ];
    var emails = [
      for (final r in await _db.query('contact_emails', where: 'contact_id = ?', whereArgs: [id], orderBy: 'id'))
        ContactValue(value: r['address'] as String, label: r['label'] as String?, isDefault: r['is_default'] == 1),
    ];
    if (phones.isEmpty && c.phoneRaw.isNotEmpty) phones = [ContactValue(value: c.phoneRaw, normalized: c.phoneNormalized)];
    if (emails.isEmpty && (c.email?.isNotEmpty ?? false)) emails = [ContactValue(value: c.email!)];
    return ContactDetails(
      contact: c, phones: phones, emails: emails,
      dates: [
        for (final r in await _db.query('contact_dates', where: 'contact_id = ?', whereArgs: [id], orderBy: 'id'))
          ContactDate(kind: r['kind'] as String, value: r['value'] as String, label: r['label'] as String?),
      ],
      preferredPhone: rows.first['preferred_phone'] as String?,
      preferredEmail: rows.first['preferred_email'] as String?,
    );
  }

  /// The number to text this contact on (kept across syncs).
  Future<void> preferPhone(int id, ContactValue phone) => _db.update('contacts', {
        'preferred_phone': phone.normalized ?? phone.value, 'phone_raw': phone.value,
        'phone_normalized': phone.normalized, 'updated_at': _now(),
      }, where: 'id = ?', whereArgs: [id]);

  /// The email to use for this contact (kept across syncs).
  Future<void> preferEmail(int id, String email) => _db.update('contacts',
      {'preferred_email': email, 'email': email, 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  /// The app contact with this number, if any.
  Future<Contact?> findByE164(String e164) async {
    // Their texting number first, then any of their other numbers.
    final rows = await _db.rawQuery('''
      SELECT c.* FROM contacts c WHERE c.phone_normalized = ?
      UNION ALL
      SELECT c.* FROM contacts c JOIN contact_phones p ON p.contact_id = c.id WHERE p.normalized = ?
      LIMIT 1''', [e164, e164]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<Set<String>> existingNormalized() async {
    final rows = await _db.query('contacts', columns: ['phone_normalized'], where: 'phone_normalized IS NOT NULL');
    return rows.map((r) => r['phone_normalized'] as String).toSet();
  }

  /// Commits ONLY the `valid` rows of a confirmed plan in a single transaction.
  /// Any failure rolls back everything (no partial import). Returns rows inserted.
  Future<int> commitImport(ImportPlan plan) async => (await commitImportToGroup(plan)).added;

  /// Like [commitImport], optionally also putting everyone from the file into
  /// a group: [groupId], or a new group called [newGroupName] created here.
  /// Rows whose number is already a contact are added to the group too (not
  /// duplicated). One transaction: on any failure nothing is saved, not even
  /// the new group.
  Future<ImportResult> commitImportToGroup(ImportPlan plan, {int? groupId, String? newGroupName}) =>
      _db.transaction((txn) async {
        final now = _now();
        final ids = <int>[];
        for (final r in plan.importable) {
          ids.add(await txn.insert('contacts', {
            'name': r.name, 'phone_raw': r.phoneRaw, 'phone_normalized': r.e164, 'email': r.email,
            'consent_status': 'unknown', 'created_at': now, 'updated_at': now,
          }));
        }
        final added = ids.length;
        var gid = groupId;
        if (newGroupName != null && newGroupName.trim().isNotEmpty) {
          gid = await txn.insert('recipient_groups', {'name': newGroupName.trim(), 'created_at': now, 'updated_at': now});
        }
        if (gid == null) return ImportResult(added: added);
        for (final r in plan.existing) {
          final rows = await txn.query('contacts', columns: ['id'], where: 'phone_normalized = ?', whereArgs: [r.e164]);
          if (rows.isNotEmpty) ids.add(rows.first['id'] as int);
        }
        final b = txn.batch();
        for (final id in ids.toSet()) {
          b.insert('group_contacts', {'group_id': gid, 'contact_id': id}, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await b.commit(noResult: true);
        return ImportResult(added: added, groupId: gid, inGroup: ids.toSet().length);
      });

  /// Saves contacts whose numbers are already normalized, in one transaction.
  /// A number that is already an app contact is reused, not duplicated (and
  /// its name and consent are left alone). Blank names fall back to the number.
  Future<UpsertResult> upsertByPhone(List<({String name, String phoneRaw, String e164})> entries) =>
      _db.transaction((txn) async {
        final now = _now();
        final ids = <int>[];
        final seen = <String, int>{};
        var added = 0, existing = 0;
        for (final e in entries) {
          if (seen.containsKey(e.e164)) continue;
          final rows = await txn.query('contacts', columns: ['id'], where: 'phone_normalized = ?', whereArgs: [e.e164]);
          final int id;
          if (rows.isNotEmpty) {
            id = rows.first['id'] as int;
            existing++;
          } else {
            id = await txn.insert('contacts', {
              'name': e.name.trim().isEmpty ? e.e164 : e.name.trim(), 'phone_raw': e.phoneRaw,
              'phone_normalized': e.e164, 'consent_status': 'unknown', 'created_at': now, 'updated_at': now,
            });
            added++;
          }
          seen[e.e164] = id;
          ids.add(id);
        }
        return UpsertResult(ids: ids, added: added, existing: existing);
      });

  // --- suppression list ---
  Future<void> suppress(String e164, {String? reason}) => _db.insert('suppression_list',
      {'phone_number_normalized': e164, 'reason': reason, 'created_at': _now()},
      conflictAlgorithm: ConflictAlgorithm.ignore);
  Future<void> unsuppress(String e164) =>
      _db.delete('suppression_list', where: 'phone_number_normalized = ?', whereArgs: [e164]);
  Future<Set<String>> suppressedNumbers() async =>
      (await _db.query('suppression_list')).map((r) => r['phone_number_normalized'] as String).toSet();
}
