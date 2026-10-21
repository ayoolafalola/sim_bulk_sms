import 'package:sqflite/sqflite.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

const _campaignToDb = {
  CampaignStatus.draft: 'draft', CampaignStatus.ready: 'ready', CampaignStatus.running: 'running',
  CampaignStatus.awaitingUserAction: 'awaiting_user_action', CampaignStatus.paused: 'paused',
  CampaignStatus.completed: 'completed', CampaignStatus.partiallyCompleted: 'partially_completed',
  CampaignStatus.failed: 'failed', CampaignStatus.cancelled: 'cancelled',
};
const _recipientToDb = {
  RecipientStatus.pending: 'pending', RecipientStatus.prepared: 'prepared',
  RecipientStatus.awaitingUserAction: 'awaiting_user_action', RecipientStatus.submitted: 'submitted',
  RecipientStatus.sent: 'sent', RecipientStatus.delivered: 'delivered', RecipientStatus.failed: 'failed',
  RecipientStatus.cancelled: 'cancelled', RecipientStatus.unknown: 'unknown',
};
CampaignStatus campaignStatusFromDb(String s) =>
    _campaignToDb.entries.firstWhere((e) => e.value == s, orElse: () => const MapEntry(CampaignStatus.failed, 'failed')).key;
RecipientStatus recipientStatusFromDb(String s) =>
    _recipientToDb.entries.firstWhere((e) => e.value == s, orElse: () => const MapEntry(RecipientStatus.unknown, 'unknown')).key;
String recipientStatusToDb(RecipientStatus s) => _recipientToDb[s]!;

class CampaignRepository {
  CampaignRepository(this._db);
  final Database _db;

  Campaign _fromRow(Map<String, Object?> r) => Campaign(
      id: r['id'] as int, name: r['name'] as String, messageTemplate: r['message_template'] as String,
      status: campaignStatusFromDb(r['status'] as String), platform: r['platform'] as String,
      subscriptionId: r['subscription_id'] as int?, recipientCount: r['recipient_count'] as int,
      createdAt: DateTime.parse(r['created_at'] as String));

  Future<int> createDraft({required String name, required String template, required String platform}) {
    final now = _now();
    return _db.insert('campaigns', {
      'name': name.trim(), 'message_template': template, 'status': 'draft', 'platform': platform,
      'recipient_count': 0, 'created_at': now, 'updated_at': now,
    });
  }

  /// Editing the template invalidates rendered messages, so the campaign goes
  /// back to `draft` and must be re-snapshotted before it can be confirmed.
  Future<void> updateDraft(int id, {required String name, required String template}) =>
      _db.transaction((txn) async {
        await _assertEditable(txn, id);
        await txn.delete('campaign_recipients', where: 'campaign_id = ?', whereArgs: [id]);
        await txn.update('campaigns', {
          'name': name.trim(), 'message_template': template, 'status': 'draft',
          'recipient_count': 0, 'updated_at': _now(),
        }, where: 'id = ?', whereArgs: [id]);
      });

  Future<void> _assertEditable(DatabaseExecutor ex, int id) async {
    final rows = await ex.query('campaigns', columns: ['status'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) throw StateError('Campaign $id not found');
    final s = rows.first['status'] as String;
    if (s != 'draft' && s != 'ready') throw SnapshotLockedException(s);
  }

  /// Atomically replaces the recipient snapshot of a draft/ready campaign.
  /// Refuses once the campaign has started (immutable snapshot, spec FR-03).
  Future<void> saveSnapshot(int campaignId, List<SnapshotRecipient> recipients) =>
      _db.transaction((txn) async {
        await _assertEditable(txn, campaignId);
        await txn.delete('campaign_recipients', where: 'campaign_id = ?', whereArgs: [campaignId]);
        final now = _now();
        final b = txn.batch();
        for (final r in recipients) {
          b.insert('campaign_recipients', {
            'campaign_id': campaignId, 'contact_id': r.contactId,
            'recipient_name_snapshot': r.name, 'phone_number_snapshot': r.phoneE164,
            'rendered_message': r.renderedMessage, 'status': 'pending', 'attempt_count': 0,
            'created_at': now, 'updated_at': now,
          });
        }
        await b.commit(noResult: true);
        await txn.update('campaigns',
            {'recipient_count': recipients.length, 'status': recipients.isEmpty ? 'draft' : 'ready', 'updated_at': _now()},
            where: 'id = ?', whereArgs: [campaignId]);
      });

  Future<void> setStatus(int id, CampaignStatus s) => _db.update('campaigns',
      {'status': _campaignToDb[s], 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  Future<void> delete(int id) => _db.delete('campaigns', where: 'id = ?', whereArgs: [id]);

  Future<Campaign?> get(int id) async {
    final rows = await _db.query('campaigns', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<List<Campaign>> recent({int limit = 10}) async =>
      (await _db.query('campaigns', orderBy: 'created_at DESC, id DESC', limit: limit)).map(_fromRow).toList();

  Future<int> countByStatus(CampaignStatus s) async => Sqflite.firstIntValue(await _db.rawQuery(
          'SELECT COUNT(*) FROM campaigns WHERE status = ?', [_campaignToDb[s]])) ?? 0;

  Future<List<CampaignRecipient>> recipients(int campaignId) async {
    final rows = await _db.query('campaign_recipients', where: 'campaign_id = ?', whereArgs: [campaignId], orderBy: 'id');
    return rows.map((r) => CampaignRecipient(
        id: r['id'] as int, campaignId: campaignId, contactId: r['contact_id'] as int?,
        name: r['recipient_name_snapshot'] as String, phone: r['phone_number_snapshot'] as String,
        renderedMessage: r['rendered_message'] as String,
        status: recipientStatusFromDb(r['status'] as String), attemptCount: r['attempt_count'] as int)).toList();
  }

  Future<Map<RecipientStatus, int>> statusCounts(int campaignId) async {
    final rows = await _db.rawQuery(
        'SELECT status, COUNT(*) AS n FROM campaign_recipients WHERE campaign_id = ? GROUP BY status', [campaignId]);
    return {for (final r in rows) recipientStatusFromDb(r['status'] as String): r['n'] as int};
  }
}
