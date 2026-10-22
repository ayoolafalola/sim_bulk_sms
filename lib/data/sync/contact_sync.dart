import 'package:sqflite/sqflite.dart';
import '../../core/phone_numbers/phone_normalizer.dart';
import '../../platform/contacts/phone_contacts_service.dart';

class ContactSyncResult {
  const ContactSyncResult({this.added = 0, this.updated = 0, this.removed = 0});
  final int added, updated, removed;
  int get changed => added + updated + removed;
}

String _now() => DateTime.now().toUtc().toIso8601String();

/// Mirrors the phone's contacts into the app (phone → app, read-only on the
/// phone). One transaction per run: matched by the phone's contact identity,
/// else merged into an app contact with the same number. App-only details
/// (consent, groups, suppression, chosen number/email) are kept. Contacts
/// deleted on the phone are removed; past campaigns keep their own copy.
class ContactSync {
  ContactSync(this._db, this._normalizer);
  final Database _db;
  final PhoneNormalizer _normalizer;

  Future<ContactSyncResult> apply(ContactsSnapshot snap) => _db.transaction((txn) async {
        // Existing rows, loaded once.
        final byLookup = <String, Map<String, Object?>>{};
        final byPhoneId = <int, Map<String, Object?>>{};
        final appByNumber = <String, int>{};
        for (final r in await txn.query('contacts',
            columns: ['id', 'source', 'lookup_key', 'phone_contact_id', 'phone_normalized', 'preferred_phone', 'preferred_email'])) {
          final lk = r['lookup_key'] as String?;
          if (lk != null) byLookup[lk] = r;
          final pid = r['phone_contact_id'] as int?;
          if (r['source'] == 'phone' && pid != null && pid > 0) byPhoneId[pid] = r;
          final n = r['phone_normalized'] as String?;
          if (r['source'] == 'app' && lk == null && n != null) appByNumber.putIfAbsent(n, () => r['id'] as int);
        }

        final now = _now();
        final inserts = <({List<_Phone> phones, SyncedContact c, String? email})>[];
        final insertRows = <Map<String, Object?>>[];
        final updates = <({int id, List<_Phone> phones, SyncedContact c, String? email, Map<String, Object?> row})>[];
        final seen = <String>{};
        final claimed = <int>{};

        for (final c in snap.contacts) {
          seen.add(c.lookupKey);
          final phones = [
            for (final p in c.phones) _Phone(p, _normalizer.normalize(p.value).e164),
          ];
          if (phones.isEmpty && c.emails.isEmpty) continue; // nothing to message
          var existing = byLookup[c.lookupKey] ?? (c.contactId > 0 ? byPhoneId[c.contactId] : null);
          if (existing == null) {
            for (final p in phones) {
              final id = p.normalized == null ? null : appByNumber[p.normalized];
              if (id != null && !claimed.contains(id)) {
                existing = {'id': id};
                break;
              }
            }
          }
          final preferredPhone = existing?['preferred_phone'] as String?;
          final preferredEmail = existing?['preferred_email'] as String?;
          final phone = _pickPhone(phones, preferredPhone);
          final email = _pickEmail(c.emails, preferredEmail);
          for (final p in phones) {
            p.isDefault = identical(p, phone);
          }
          final birthday = c.dates.where((d) => d.kind == 'birthday').firstOrNull?.value;
          final display = c.name.trim().isNotEmpty
              ? c.name.trim()
              : [c.givenName, c.familyName].whereType<String>().where((s) => s.trim().isNotEmpty).join(' ').trim();
          final row = <String, Object?>{
            'name': display.isNotEmpty ? display : (phone?.raw ?? email ?? 'Unknown'),
            'phone_raw': phone?.raw ?? '', 'phone_normalized': phone?.normalized, 'email': email,
            'source': 'phone', 'lookup_key': c.lookupKey, 'phone_contact_id': c.contactId > 0 ? c.contactId : null,
            'given_name': c.givenName, 'family_name': c.familyName, 'organization': c.organization,
            'job_title': c.jobTitle, 'birthday': birthday, 'address': c.address, 'note': c.note, 'updated_at': now,
          };
          if (existing == null) {
            inserts.add((phones: phones, c: c, email: email));
            insertRows.add({...row, 'consent_status': 'unknown', 'created_at': now});
          } else {
            final id = existing['id'] as int;
            claimed.add(id);
            updates.add((id: id, phones: phones, c: c, email: email, row: row));
          }
        }

        // New contacts first: their ids are needed for their numbers/emails/dates.
        final ins = txn.batch();
        for (final r in insertRows) {
          ins.insert('contacts', r);
        }
        final ids = await ins.commit();

        final b = txn.batch();
        void children(int id, List<_Phone> phones, SyncedContact c, String? email) {
          b.delete('contact_phones', where: 'contact_id = ?', whereArgs: [id]);
          b.delete('contact_emails', where: 'contact_id = ?', whereArgs: [id]);
          b.delete('contact_dates', where: 'contact_id = ?', whereArgs: [id]);
          for (final p in phones) {
            b.insert('contact_phones', {'contact_id': id, 'raw': p.raw, 'normalized': p.normalized,
                'label': p.v.label, 'is_default': p.isDefault ? 1 : 0});
          }
          for (final e in c.emails) {
            b.insert('contact_emails',
                {'contact_id': id, 'address': e.value, 'label': e.label, 'is_default': e.value == email ? 1 : 0});
          }
          for (final d in c.dates) {
            b.insert('contact_dates', {'contact_id': id, 'kind': d.kind ?? 'other', 'value': d.value, 'label': d.label});
          }
        }
        for (var i = 0; i < inserts.length; i++) {
          children(ids[i] as int, inserts[i].phones, inserts[i].c, inserts[i].email);
        }
        for (final u in updates) {
          b.update('contacts', u.row, where: 'id = ?', whereArgs: [u.id]);
          children(u.id, u.phones, u.c, u.email);
        }
        await b.commit(noResult: true);

        // Deleted on the phone: remove here too.
        var removed = 0;
        for (final pid in snap.deleted) {
          removed += await txn.delete('contacts', where: "source = 'phone' AND phone_contact_id = ?", whereArgs: [pid]);
        }
        if (snap.full) {
          final gone = [
            for (final e in byLookup.entries)
              if (e.value['source'] == 'phone' && !seen.contains(e.key)) e.value['id'] as int,
          ];
          for (final id in gone) {
            removed += await txn.delete('contacts', where: 'id = ?', whereArgs: [id]);
          }
        }
        return ContactSyncResult(added: inserts.length, updated: updates.length, removed: removed);
      });

  /// The number to text: the one you chose, else the phone's default, else Mobile, else the first valid one.
  static _Phone? _pickPhone(List<_Phone> phones, String? preferred) {
    if (phones.isEmpty) return null;
    if (preferred != null) {
      final p = phones.where((p) => p.normalized == preferred || p.raw == preferred).firstOrNull;
      if (p != null) return p;
    }
    final valid = phones.where((p) => p.normalized != null).toList();
    final pool = valid.isEmpty ? phones : valid;
    return pool.where((p) => p.v.primary).firstOrNull ??
        pool.where((p) => p.v.type == 2).firstOrNull ?? // ContactsContract Phone.TYPE_MOBILE
        pool.first;
  }

  /// The email to use: the one you chose, else the phone's default, else the first.
  static String? _pickEmail(List<SyncedValue> emails, String? preferred) {
    if (emails.isEmpty) return null;
    if (preferred != null && emails.any((e) => e.value == preferred)) return preferred;
    return (emails.where((e) => e.primary).firstOrNull ?? emails.first).value;
  }
}

class _Phone {
  _Phone(this.v, this.normalized);
  final SyncedValue v;
  final String? normalized;
  bool isDefault = false;
  String get raw => v.value;
}
