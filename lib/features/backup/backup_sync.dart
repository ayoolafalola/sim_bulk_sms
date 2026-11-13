import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../../platform/contacts_plus/contacts_plus_auth.dart';
import '../../platform/messages/messages_service.dart';
import 'campaign_plans.dart';

/// One synced record, as stored by Contacts++ (`/messages-plus/sync`).
class SyncRecord {
  const SyncRecord({required this.kind, required this.key, this.data, this.deleted = false, this.seq = 0});
  final String kind, key;
  final Map<String, dynamic>? data;
  final bool deleted;
  final int seq;

  Map<String, dynamic> toJson() => {'kind': kind, 'key': key, if (deleted) 'deleted': true else 'data': data};

  static SyncRecord fromJson(Map<dynamic, dynamic> j) => SyncRecord(
        kind: '${j['kind']}',
        key: '${j['key']}',
        data: (j['data'] as Map?)?.cast<String, dynamic>(),
        deleted: j['deleted'] == true,
        seq: (j['seq'] as num?)?.toInt() ?? 0,
      );
}

/// Talks to the Contacts++ sync endpoints. Abstract for tests.
abstract interface class SyncTransport {
  Future<({List<SyncRecord> records, int cursor, bool hasMore})> pull(int since, {int limit = 500});
  Future<int> push(List<SyncRecord> records);
}

class ContactsSyncTransport implements SyncTransport {
  ContactsSyncTransport(this._auth);
  final ContactsPlusAuth _auth;

  Future<String> _token() async =>
      await _auth.accessToken() ?? (throw const ContactsPlusException('Sign in to Contacts++ to back up.', statusCode: 401));

  @override
  Future<({List<SyncRecord> records, int cursor, bool hasMore})> pull(int since, {int limit = 500}) async {
    final data = (await _auth.api.get('/messages-plus/sync?since=$since&limit=$limit', token: await _token()))['data'] as Map;
    return (
      records: [for (final r in (data['records'] as List).cast<Map>()) SyncRecord.fromJson(r)],
      cursor: (data['cursor'] as num).toInt(),
      hasMore: data['has_more'] == true,
    );
  }

  @override
  Future<int> push(List<SyncRecord> records) async {
    final data = (await _auth.api.post('/messages-plus/sync', {
      'records': [for (final r in records) r.toJson()],
    }, token: await _token()))['data'] as Map;
    return (data['cursor'] as num).toInt();
  }
}

/// A named step of a backup run, for "2/5 · Backing up groups · 12/40".
class SyncProgress {
  const SyncProgress(this.step, this.total, this.label, {this.done = 0, this.of = 0});
  final int step, total, done, of;
  final String label;
}

/// What a run did.
class SyncReport {
  const SyncReport({this.uploaded = 0, this.downloaded = 0, this.removed = 0});
  final int uploaded, downloaded, removed;
}

/// Backup and sync with Contacts++.
///
/// - Contacts and groups go both ways: a change on the web or another phone
///   arrives here, and a change here reaches them.
/// - Campaigns (with their results) and texts are backed up from the phone;
///   the web shows them read-only.
/// - Campaign plans go both ways whenever signed in (see [CampaignPlans]):
///   a campaign set up on the web is saved and scheduled here, and this
///   phone reports what it did with it. The backup switch only decides
///   whether this phone's own data (contacts, groups, its own campaigns,
///   texts) is uploaded; changes from the web always arrive.
///
/// Only changed records are sent: each local row keeps the hash of what was
/// last uploaded (`sync_links`). Nothing on the phone is deleted because of
/// a deletion elsewhere, except contacts and groups the member removed.
class BackupSync {
  BackupSync({required this.db, required this.transport, this.messages, this.plans, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Database db;
  final SyncTransport transport;
  final MessagesService? messages;
  final CampaignPlans? plans;
  final DateTime Function() _clock;

  static const _cursorKey = 'cpp_sync_cursor';
  static const _batch = 200;
  static const _messageDays = 90;

  /// A full run uploads this phone's data too (backup on); otherwise only
  /// web changes come down and campaign plans and their status go up.
  Future<SyncReport> run({void Function(SyncProgress)? onProgress, bool full = true}) async {
    if (!full) {
      final downloaded = await _pull();
      final uploaded = await _syncPlans(includeNew: false);
      return SyncReport(uploaded: uploaded, downloaded: downloaded);
    }
    const total = 5;
    // Remote first: a contact edited on the web shouldn't be overwritten by
    // the older copy here.
    onProgress?.call(const SyncProgress(1, total, 'Getting changes from your other devices'));
    final downloaded = await _pull();
    var uploaded = 0, removed = 0;

    onProgress?.call(const SyncProgress(2, total, 'Backing up contacts'));
    final contacts = await _contactRecords();
    final c = await _upload('contact', contacts, (d, n) => onProgress?.call(SyncProgress(2, total, 'Backing up contacts', done: d, of: n)));
    uploaded += c.$1;
    removed += c.$2;

    onProgress?.call(const SyncProgress(3, total, 'Backing up groups'));
    final g = await _upload('group', await _groupRecords(), null);
    uploaded += g.$1;
    removed += g.$2;

    onProgress?.call(const SyncProgress(4, total, 'Backing up campaigns'));
    final k = await _upload('campaign', await _campaignRecords(), null, removeMissing: false);
    uploaded += k.$1;

    onProgress?.call(const SyncProgress(5, total, 'Backing up texts'));
    final m = await _upload('message', await _messageRecords(), (d, n) => onProgress?.call(SyncProgress(5, total, 'Backing up texts', done: d, of: n)),
        removeMissing: false);
    uploaded += m.$1;
    uploaded += await _syncPlans(includeNew: true);

    await _setSetting('cpp_last_backup_at', _clock().toUtc().toIso8601String());
    return SyncReport(uploaded: uploaded, downloaded: downloaded, removed: removed);
  }

  Future<DateTime?> lastBackupAt() async =>
      DateTime.tryParse(await _setting('cpp_last_backup_at') ?? '')?.toLocal();

  /// Uploads changed campaign plans, then what this phone did with each.
  Future<int> _syncPlans({required bool includeNew}) async {
    final p = plans;
    if (p == null) return 0;
    final k = await _upload(CampaignPlans.planKind, await p.records(includeNew: includeNew), null,
        hasher: CampaignPlans.hashPlan, uploaded: p.markUploaded);
    final s = await _upload(CampaignPlans.statusKind, await p.statuses(), null, keyFor: p.keyFor);
    return k.$1 + s.$1;
  }

  // ---- Local → records (keyed by local id) -------------------------------

  Future<Map<int, Map<String, dynamic>>> _contactRecords({int? id}) async {
    final rows = await db.query('contacts', where: id == null ? null : 'id = ?', whereArgs: id == null ? null : [id], orderBy: 'id');
    return {
      for (final r in rows)
        r['id'] as int: {
          'name': r['name'],
          'phone': r['phone_normalized'] ?? r['phone_raw'],
          'email': r['email'],
          'organization': r['organization'],
          'birthday': r['birthday'],
          'consent': r['consent_status'],
          'source': r['source'],
        },
    };
  }

  Future<Map<int, Map<String, dynamic>>> _groupRecords({int? id}) async {
    final groups = await db.query('recipient_groups', where: id == null ? null : 'id = ?', whereArgs: id == null ? null : [id], orderBy: 'id');
    final members = await db.rawQuery('''
      SELECT gc.group_id, l.sync_key FROM group_contacts gc
      JOIN sync_links l ON l.kind = 'contact' AND l.local_id = gc.contact_id${id == null ? '' : ' WHERE gc.group_id = ?'}''',
        [if (id != null) id]);
    final byGroup = <int, List<String>>{};
    for (final m in members) {
      byGroup.putIfAbsent(m['group_id'] as int, () => []).add(m['sync_key'] as String);
    }
    return {
      for (final g in groups) g['id'] as int: {'name': g['name'], 'members': (byGroup[g['id']] ?? [])..sort()},
    };
  }

  Future<Map<int, Map<String, dynamic>>> _campaignRecords() async {
    final campaigns = await db.query('campaigns', where: "status <> 'draft'", orderBy: 'id');
    final counts = await db.rawQuery(
        'SELECT campaign_id, status, COUNT(*) AS n FROM campaign_recipients GROUP BY campaign_id, status');
    final byCampaign = <int, Map<String, int>>{};
    for (final c in counts) {
      byCampaign.putIfAbsent(c['campaign_id'] as int, () => {})[c['status'] as String] = c['n'] as int;
    }
    return {
      for (final c in campaigns)
        c['id'] as int: {
          'name': c['name'],
          'template': c['message_template'],
          'status': c['status'],
          'created_at': c['created_at'],
          'completed_at': c['completed_at'],
          'recipients': byCampaign[c['id']] ?? const {},
        },
    };
  }

  /// Texts of the last 90 days (Android, while the default messaging app),
  /// plus campaign texts sent from this app on any phone.
  Future<Map<int, Map<String, dynamic>>> _messageRecords() async {
    final since = _clock().subtract(const Duration(days: _messageDays));
    final out = <int, Map<String, dynamic>>{};
    final svc = messages;
    if (svc != null) {
      try {
        if (await svc.isDefault()) {
          for (final thread in await svc.conversations()) {
            if (thread.date.isBefore(since)) continue;
            for (final m in await svc.messages(thread.threadId, limit: 500)) {
              if (m.date.isBefore(since)) continue;
              out[m.id] = {
                'thread': m.address,
                'name': thread.name,
                'body': m.body,
                'incoming': m.incoming,
                'status': m.status.name,
                'at': m.date.toUtc().toIso8601String(),
              };
            }
          }
        }
      } catch (_) {
        // The phone's message store isn't readable: campaign texts only.
      }
    }
    // Campaign texts (all platforms). Negative ids keep them apart from
    // Android's own message ids.
    final sent = await db.rawQuery('''
      SELECT a.id, a.sent_body, a.platform, a.status, a.initiated_at, r.phone_number_snapshot, r.recipient_name_snapshot
      FROM send_attempts a JOIN campaign_recipients r ON r.id = a.campaign_recipient_id
      WHERE a.sent_body IS NOT NULL AND a.platform <> 'email' AND a.initiated_at >= ?''',
        [since.toUtc().toIso8601String()]);
    for (final a in sent) {
      out[-(a['id'] as int)] = {
        'thread': a['phone_number_snapshot'],
        'name': a['recipient_name_snapshot'],
        'body': a['sent_body'],
        'incoming': false,
        'status': a['status'],
        'via': a['platform'] == 'contacts_chat' ? 'chat' : 'sms',
        'at': a['initiated_at'],
      };
    }
    return out;
  }

  // ---- Upload ------------------------------------------------------------

  /// Uploads new and changed records of [kind]; with [removeMissing], rows
  /// deleted here become deletions everywhere. Returns (uploaded, removed).
  /// [hasher] decides what counts as a change; [keyFor] gives a record the
  /// key of another (a plan's status shares the plan's key); [uploaded] is
  /// told about each record sent.
  Future<(int, int)> _upload(String kind, Map<int, Map<String, dynamic>> current, void Function(int, int)? progress,
      {bool removeMissing = true,
      String Function(Map<String, dynamic>)? hasher,
      Future<String?> Function(int localId)? keyFor,
      Future<void> Function(String key, Map<String, dynamic> data)? uploaded}) async {
    final links = {
      for (final l in await db.query('sync_links', where: 'kind = ?', whereArgs: [kind])) l['local_id'] as int: l,
    };
    final changed = <(int, SyncRecord, String)>[];
    for (final e in current.entries) {
      final hash = (hasher ?? _hash)(e.value);
      final link = links[e.key];
      if (link != null && link['hash'] == hash) continue;
      final key = link?['sync_key'] as String? ??
          (keyFor == null ? ContactsChatService.newClientId() : await keyFor(e.key));
      if (key == null) continue;
      changed.add((e.key, SyncRecord(kind: kind, key: key, data: e.value), hash));
    }
    final gone = removeMissing
        ? [for (final l in links.values) if (!current.containsKey(l['local_id'])) l]
        : const <Map<String, Object?>>[];
    final total = changed.length + gone.length;
    var done = 0;
    for (var i = 0; i < changed.length; i += _batch) {
      final chunk = changed.sublist(i, (i + _batch).clamp(0, changed.length));
      final seq = await transport.push([for (final c in chunk) c.$2]);
      final b = db.batch();
      for (final (localId, record, hash) in chunk) {
        b.insert('sync_links', {'kind': kind, 'local_id': localId, 'sync_key': record.key, 'hash': hash, 'seq': seq},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
      for (final (_, record, _) in chunk) {
        await uploaded?.call(record.key, record.data!);
      }
      done += chunk.length;
      progress?.call(done, total);
    }
    for (var i = 0; i < gone.length; i += _batch) {
      final chunk = gone.sublist(i, (i + _batch).clamp(0, gone.length));
      await transport.push([for (final l in chunk) SyncRecord(kind: kind, key: l['sync_key'] as String, deleted: true)]);
      final b = db.batch();
      for (final l in chunk) {
        b.delete('sync_links', where: 'kind = ? AND local_id = ?', whereArgs: [kind, l['local_id']]);
      }
      await b.commit(noResult: true);
      done += chunk.length;
      progress?.call(done, total);
    }
    return (changed.length, gone.length);
  }

  // ---- Download (contacts, groups, campaign plans) ----------------------

  Future<int> _pull() async {
    var cursor = int.tryParse(await _setting(_cursorKey) ?? '') ?? 0;
    var applied = 0;
    while (true) {
      final page = await transport.pull(cursor);
      // Contacts before groups, so group members resolve; then campaign
      // plans, whose audiences name both.
      final ordered = [...page.records.where((r) => r.kind == 'contact'), ...page.records.where((r) => r.kind == 'group')];
      for (final r in ordered) {
        if (await _apply(r)) applied++;
      }
      final p = plans;
      if (p != null) {
        for (final r in page.records.where((r) => r.kind == CampaignPlans.planKind)) {
          if (await p.apply(key: r.key, seq: r.seq, deleted: r.deleted, data: r.data)) applied++;
        }
      }
      cursor = page.cursor;
      await _setSetting(_cursorKey, '$cursor');
      if (!page.hasMore) break;
    }
    return applied;
  }

  /// Applies one remote change. Skips echoes of this phone's own uploads.
  Future<bool> _apply(SyncRecord r) async {
    final link = (await db.query('sync_links', where: 'kind = ? AND sync_key = ?', whereArgs: [r.kind, r.key])).firstOrNull;
    if (link != null && (link['seq'] as int) >= r.seq) return false;
    final now = _clock().toUtc().toIso8601String();
    if (r.deleted) {
      if (link == null) return false;
      final table = r.kind == 'contact' ? 'contacts' : 'recipient_groups';
      // Phone-synced contacts belong to the phone's address book: keep them.
      await db.delete(table,
          where: r.kind == 'contact' ? "id = ? AND source <> 'phone'" : 'id = ?', whereArgs: [link['local_id']]);
      await db.delete('sync_links', where: 'kind = ? AND local_id = ?', whereArgs: [r.kind, link['local_id']]);
      return true;
    }
    final d = r.data ?? const {};
    int localId;
    if (r.kind == 'contact') {
      final phone = '${d['phone'] ?? ''}';
      final values = {
        'name': '${d['name'] ?? phone}',
        'email': d['email'],
        'organization': d['organization'],
        'birthday': d['birthday'],
        if (d['consent'] is String) 'consent_status': d['consent'],
        'updated_at': now,
      };
      if (link != null) {
        localId = link['local_id'] as int;
        await db.update('contacts', values, where: 'id = ?', whereArgs: [localId]);
        // A new number from the web: only for people this app keeps (the
        // phone's own contacts are edited in the phone's Contacts app).
        if (phone.isNotEmpty) {
          await db.update('contacts', {'phone_raw': phone, 'phone_normalized': phone.startsWith('+') ? phone : null},
              where: "id = ? AND source <> 'phone' AND COALESCE(phone_normalized, phone_raw, '') <> ?", whereArgs: [localId, phone]);
        }
      } else {
        // Same number already here (e.g. from the phone's contacts): link it.
        final same = phone.isEmpty
            ? null
            : (await db.query('contacts', where: 'phone_normalized = ?', whereArgs: [phone], limit: 1)).firstOrNull;
        localId = same?['id'] as int? ??
            await db.insert('contacts', {
              ...values,
              'phone_raw': phone,
              'phone_normalized': phone.startsWith('+') ? phone : null,
              'source': 'app',
              'created_at': now,
            });
      }
    } else if (r.kind == 'group') {
      final name = '${d['name'] ?? 'Group'}';
      if (link != null) {
        localId = link['local_id'] as int;
        await db.update('recipient_groups', {'name': name, 'updated_at': now}, where: 'id = ?', whereArgs: [localId]);
      } else {
        localId = await db.insert('recipient_groups', {'name': name, 'created_at': now, 'updated_at': now});
      }
      final keys = [for (final k in (d['members'] as List? ?? const [])) '$k'];
      final ids = keys.isEmpty
          ? const <int>[]
          : [
              for (final row in await db.query('sync_links',
                  where: "kind = 'contact' AND sync_key IN (${List.filled(keys.length, '?').join(',')})", whereArgs: keys))
                row['local_id'] as int,
            ];
      final b = db.batch()..delete('group_contacts', where: 'group_id = ?', whereArgs: [localId]);
      for (final id in ids) {
        b.insert('group_contacts', {'group_id': localId, 'contact_id': id}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await b.commit(noResult: true);
    } else {
      return false; // campaigns and texts are backed up, not restored as live rows
    }
    // Remember it with its current hash so it isn't uploaded straight back.
    final current = r.kind == 'contact'
        ? (await _contactRecords(id: localId))[localId]
        : (await _groupRecords(id: localId))[localId];
    await db.insert('sync_links',
        {'kind': r.kind, 'local_id': localId, 'sync_key': r.key, 'hash': current == null ? null : _hash(current), 'seq': r.seq},
        conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  // ---- Helpers -----------------------------------------------------------

  static String _hash(Map<String, dynamic> data) => sha1.convert(utf8.encode(jsonEncode(data))).toString();

  Future<String?> _setting(String key) async =>
      (await db.query('app_settings', where: 'key = ?', whereArgs: [key])).firstOrNull?['value'] as String?;

  Future<void> _setSetting(String key, String value) =>
      db.insert('app_settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
}
