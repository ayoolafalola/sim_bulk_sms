import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/channels.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';
import '../../domain/services/send_limits.dart';

String _now() => DateTime.now().toUtc().toIso8601String();
/// UTC ISO with millisecond precision, so stored instants compare correctly as text.
String _utcMs(DateTime d) => DateTime.fromMillisecondsSinceEpoch(d.millisecondsSinceEpoch, isUtc: true).toIso8601String();

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

CampaignRecipient recipientFromRow(Map<String, Object?> r) => CampaignRecipient(
    id: r['id'] as int, campaignId: r['campaign_id'] as int, contactId: r['contact_id'] as int?,
    name: r['recipient_name_snapshot'] as String, phone: r['phone_number_snapshot'] as String,
    renderedMessage: r['rendered_message'] as String,
    status: recipientStatusFromDb(r['status'] as String), attemptCount: r['attempt_count'] as int,
    channel: messageChannelFromDb(r['channel'] as String?), email: r['email_snapshot'] as String?,
    subject: r['rendered_subject'] as String?);

class CampaignRepository {
  CampaignRepository(this._db);
  final Database _db;

  Campaign _fromRow(Map<String, Object?> r) => Campaign(
      id: r['id'] as int, name: r['name'] as String, messageTemplate: r['message_template'] as String,
      status: campaignStatusFromDb(r['status'] as String), platform: r['platform'] as String,
      subscriptionId: r['subscription_id'] as int?, recipientCount: r['recipient_count'] as int,
      createdAt: DateTime.parse(r['created_at'] as String),
      sourceCampaignId: r['source_campaign_id'] as int?, scheduleId: r['schedule_id'] as int?,
      pausedReason: r['paused_reason'] as String?,
      resumeAt: r['resume_at'] == null ? null : DateTime.parse(r['resume_at'] as String).toLocal(),
      channel: sendChannelFromDb(r['channel'] as String?), subject: r['subject'] as String?);

  Future<int> createDraft({
    required String name, required String template, required String platform,
    int? sourceCampaignId, int? scheduleId, Map<String, String> fallbacks = const {},
    SendChannel channel = SendChannel.sms, String? subject,
  }) {
    final now = _now();
    return _db.insert('campaigns', {
      'name': name.trim(), 'message_template': template, 'status': 'draft', 'platform': platform,
      'recipient_count': 0, 'created_at': now, 'updated_at': now,
      'source_campaign_id': sourceCampaignId, 'schedule_id': scheduleId,
      'fallbacks_json': fallbacks.isEmpty ? null : jsonEncode(fallbacks),
      'channel': sendChannelToDb(channel), 'subject': subject,
    });
  }

  /// Replaces who the campaign targets. Stored so it can be edited, resent to
  /// current group members, and run on a schedule.
  Future<void> saveAudience(int campaignId, CampaignAudience a) => _db.transaction((txn) async {
        await txn.delete('campaign_audience', where: 'campaign_id = ?', whereArgs: [campaignId]);
        final b = txn.batch();
        for (final g in a.groupIds) {
          b.insert('campaign_audience', {'campaign_id': campaignId, 'group_id': g});
        }
        for (final c in a.contactIds) {
          b.insert('campaign_audience', {'campaign_id': campaignId, 'contact_id': c});
        }
        await b.commit(noResult: true);
      });

  Future<CampaignAudience> audience(int campaignId) async {
    final rows = await _db.query('campaign_audience', where: 'campaign_id = ?', whereArgs: [campaignId]);
    return CampaignAudience(
      groupIds: {for (final r in rows) if (r['group_id'] != null) r['group_id'] as int},
      contactIds: {for (final r in rows) if (r['contact_id'] != null) r['contact_id'] as int},
    );
  }

  Future<void> saveFallbacks(int campaignId, Map<String, String> fallbacks) => _db.update('campaigns',
      {'fallbacks_json': fallbacks.isEmpty ? null : jsonEncode(fallbacks), 'updated_at': _now()},
      where: 'id = ?', whereArgs: [campaignId]);

  Future<Map<String, String>> fallbacks(int campaignId) async {
    final rows = await _db.query('campaigns', columns: ['fallbacks_json'], where: 'id = ?', whereArgs: [campaignId]);
    final j = rows.isEmpty ? null : rows.first['fallbacks_json'] as String?;
    return j == null ? {} : Map<String, String>.from(jsonDecode(j) as Map);
  }

  /// True while any campaign is sending or waiting on the user, so a scheduled
  /// run never overlaps another send.
  Future<bool> anySending() async => (Sqflite.firstIntValue(await _db.rawQuery(
          "SELECT COUNT(*) FROM campaigns WHERE status IN ('running','awaiting_user_action')")) ?? 0) > 0;

  /// Editing the template invalidates rendered messages, so the campaign goes
  /// back to `draft` and must be re-snapshotted before it can be confirmed.
  Future<void> updateDraft(int id,
          {required String name, required String template, SendChannel? channel, String? subject}) =>
      _db.transaction((txn) async {
        await _assertEditable(txn, id);
        await txn.delete('campaign_recipients', where: 'campaign_id = ?', whereArgs: [id]);
        await txn.update('campaigns', {
          'name': name.trim(), 'message_template': template, 'status': 'draft',
          'recipient_count': 0, 'updated_at': _now(),
          if (channel != null) 'channel': sendChannelToDb(channel),
          if (channel != null) 'subject': subject,
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
            'channel': r.channel == MessageChannel.email ? 'email' : 'sms',
            'email_snapshot': r.email, 'rendered_subject': r.subject,
          });
        }
        await b.commit(noResult: true);
        await txn.update('campaigns',
            {'recipient_count': recipients.length, 'status': recipients.isEmpty ? 'draft' : 'ready', 'updated_at': _now()},
            where: 'id = ?', whereArgs: [campaignId]);
      });

  Future<void> setStatus(int id, CampaignStatus s) => _db.update('campaigns',
      {'status': _campaignToDb[s], 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  /// Asks a running send to stop after its current message (the sender checks
  /// the status before each one). No effect unless the campaign is running.
  Future<void> requestPause(int id) => _db.update('campaigns',
      {'status': 'paused', 'paused_reason': 'user', 'resume_at': null, 'updated_at': _now()},
      where: "id = ? AND status = 'running'", whereArgs: [id]);

  /// Pauses a running campaign at a send limit; it resumes by itself at [resumeAt].
  Future<void> pauseForLimit(int id, LimitKind kind, DateTime resumeAt, {bool email = false}) =>
      _db.update('campaigns', {
        'status': 'paused',
        'paused_reason': '${email ? 'email_' : ''}${kind == LimitKind.hourly ? 'hourly_limit' : 'daily_limit'}',
        'resume_at': _utcMs(resumeAt),
        'updated_at': _now(),
      }, where: "id = ? AND status = 'running'", whereArgs: [id]);

  /// Limit-paused campaigns whose resume time has come.
  Future<List<int>> dueResumes(DateTime now) async => [
        for (final r in await _db.query('campaigns', columns: ['id'],
            where: "status = 'paused' AND resume_at IS NOT NULL AND resume_at <= ?",
            whereArgs: [_utcMs(now)], orderBy: 'resume_at'))
          r['id'] as int,
      ];

  /// Earliest automatic resume, if any campaign is waiting on a limit.
  Future<DateTime?> nextResume() async {
    final rows = await _db.rawQuery(
        "SELECT MIN(resume_at) AS t FROM campaigns WHERE status = 'paused' AND resume_at IS NOT NULL");
    final t = rows.first['t'] as String?;
    return t == null ? null : DateTime.parse(t).toLocal();
  }

  Future<void> delete(int id) => _db.delete('campaigns', where: 'id = ?', whereArgs: [id]);

  Future<Campaign?> get(int id) async {
    final rows = await _db.query('campaigns', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<List<Campaign>> recent({int limit = 10}) async =>
      (await _db.query('campaigns', orderBy: 'created_at DESC, id DESC', limit: limit)).map(_fromRow).toList();

  Future<int> countByStatus(CampaignStatus s) async => Sqflite.firstIntValue(await _db.rawQuery(
          'SELECT COUNT(*) FROM campaigns WHERE status = ?', [_campaignToDb[s]])) ?? 0;

  /// For texts in the phone's message store: which campaign each one was sent by.
  Future<Map<int, ({int campaignId, String name})>> campaignsForStoredMessages(Iterable<int> smsIds) async {
    final ids = smsIds.toList();
    if (ids.isEmpty) return const {};
    final rows = await _db.rawQuery('''
      SELECT s.sms_id, c.id AS campaign_id, c.name FROM stored_messages s
      JOIN campaign_recipients r ON r.id = s.campaign_recipient_id JOIN campaigns c ON c.id = r.campaign_id
      WHERE s.sms_id IN (${List.filled(ids.length, '?').join(',')})''', ids);
    return {
      for (final r in rows) r['sms_id'] as int: (campaignId: r['campaign_id'] as int, name: r['name'] as String),
    };
  }

  /// Numbers (E.164) that campaigns texted since [since]: replies from them are "campaign replies".
  Future<Set<String>> recentlyTextedNumbers(DateTime since) async => {
        for (final r in await _db.rawQuery(
            "SELECT DISTINCT phone_number_snapshot AS p FROM campaign_recipients "
            "WHERE channel = 'sms' AND status IN ('submitted','sent','delivered') AND updated_at >= ?",
            [since.toUtc().toIso8601String()]))
          r['p'] as String,
      };

  Future<List<CampaignRecipient>> recipients(int campaignId) async {
    final rows = await _db.query('campaign_recipients', where: 'campaign_id = ?', whereArgs: [campaignId], orderBy: 'id');
    return rows.map(recipientFromRow).toList();
  }

  /// Pending rows per channel, e.g. to know whether a send needs the SIM, email, or both.
  Future<({int sms, int email})> pendingByChannel(int campaignId) async {
    final rows = await _db.rawQuery(
        "SELECT channel, COUNT(*) AS n FROM campaign_recipients WHERE campaign_id = ? AND status = 'pending' "
        'GROUP BY channel', [campaignId]);
    int n(String ch) => rows.where((r) => r['channel'] == ch).fold(0, (a, r) => a + (r['n'] as int));
    return (sms: n('sms'), email: n('email'));
  }

  Future<Map<RecipientStatus, int>> statusCounts(int campaignId, {MessageChannel? channel}) async {
    final rows = await _db.rawQuery(
        'SELECT status, COUNT(*) AS n FROM campaign_recipients WHERE campaign_id = ?'
        '${channel == null ? '' : ' AND channel = ?'} GROUP BY status',
        [campaignId, if (channel != null) channel == MessageChannel.email ? 'email' : 'sms']);
    return {for (final r in rows) recipientStatusFromDb(r['status'] as String): r['n'] as int};
  }
}
