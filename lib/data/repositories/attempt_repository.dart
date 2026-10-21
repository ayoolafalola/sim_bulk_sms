import 'package:sqflite/sqflite.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_outcome.dart';
import '../../domain/services/recipient_state_machine.dart';
import 'campaign_repository.dart';

String _now() => DateTime.now().toUtc().toIso8601String();

class AttemptRefusedException implements Exception {
  AttemptRefusedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Persistent send queue. Every attempt row is written BEFORE the native send is
/// invoked, so a crash can only produce an `unknown` outcome, never a silent
/// duplicate. All status changes go through [RecipientStateMachine].
class AttemptRepository {
  AttemptRepository(this._db);
  final Database _db;

  static const _inFlight = "('prepared','submitted','awaiting_user_action')";

  Future<CampaignRecipient?> nextPending(int campaignId) async {
    final rows = await _db.query('campaign_recipients',
        where: "campaign_id = ? AND status = 'pending'", whereArgs: [campaignId], orderBy: 'id', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return CampaignRecipient(
        id: r['id'] as int, campaignId: campaignId, contactId: r['contact_id'] as int?,
        name: r['recipient_name_snapshot'] as String, phone: r['phone_number_snapshot'] as String,
        renderedMessage: r['rendered_message'] as String,
        status: recipientStatusFromDb(r['status'] as String), attemptCount: r['attempt_count'] as int);
  }

  /// Creates attempt N for a `pending` recipient and moves it to `prepared`.
  /// Refuses anything else, so a recipient that may already have been sent can't be re-sent.
  Future<int> beginAttempt(int recipientId, String platform) => _db.transaction((txn) async {
        final rows = await txn.query('campaign_recipients', where: 'id = ?', whereArgs: [recipientId]);
        if (rows.isEmpty) throw AttemptRefusedException('Recipient not found.');
        final st = recipientStatusFromDb(rows.first['status'] as String);
        if (st != RecipientStatus.pending) {
          throw AttemptRefusedException('Recipient is ${st.name}; refusing to start another attempt.');
        }
        final n = (rows.first['attempt_count'] as int) + 1;
        final now = _now();
        final id = await txn.insert('send_attempts', {
          'campaign_recipient_id': recipientId, 'attempt_number': n, 'platform': platform,
          'status': 'prepared', 'initiated_at': now,
        });
        await txn.update('campaign_recipients', {'status': 'prepared', 'attempt_count': n, 'updated_at': now},
            where: 'id = ?', whereArgs: [recipientId]);
        return id;
      });

  /// Applies a status change to an attempt (and to its recipient if it is the
  /// latest attempt). Returns the campaign id if applied, or null if the change
  /// was invalid/duplicate/late and therefore ignored (idempotent).
  Future<int?> applyResult(int attemptId, RecipientStatus next, {String? errorCode, String? errorMessage}) =>
      _db.transaction((txn) async {
        final a = await txn.query('send_attempts', where: 'id = ?', whereArgs: [attemptId]);
        if (a.isEmpty) return null;
        final cur = recipientStatusFromDb(a.first['status'] as String);
        if (!RecipientStateMachine.canTransition(cur, next)) return null;
        final now = _now();
        final settled = next != RecipientStatus.prepared && next != RecipientStatus.submitted &&
            next != RecipientStatus.awaitingUserAction;
        await txn.update('send_attempts', {
          'status': recipientStatusToDb(next),
          if (errorCode != null) 'error_code': errorCode,
          if (errorMessage != null) 'error_description': errorMessage,
          'result_at': settled ? now : null,
        }, where: 'id = ?', whereArgs: [attemptId]);

        final rid = a.first['campaign_recipient_id'] as int;
        final r = (await txn.query('campaign_recipients', where: 'id = ?', whereArgs: [rid])).first;
        if (r['attempt_count'] == a.first['attempt_number']) {
          final rcur = recipientStatusFromDb(r['status'] as String);
          if (RecipientStateMachine.canTransition(rcur, next)) {
            await txn.update('campaign_recipients', {
              'status': recipientStatusToDb(next),
              if (errorCode != null) 'last_error_code': errorCode,
              if (errorMessage != null) 'last_error_message': errorMessage,
              'updated_at': now,
            }, where: 'id = ?', whereArgs: [rid]);
          }
        }
        return r['campaign_id'] as int;
      });

  /// Run at app start. Anything in flight has an uncertain outcome -> `unknown`
  /// (never auto-retried). Running campaigns are paused so the user decides.
  /// Returns the number of recipients moved to `unknown`.
  Future<int> recoverInterrupted() => _db.transaction((txn) async {
        final now = _now();
        await txn.rawUpdate(
            "UPDATE send_attempts SET status='unknown', result_at=?, error_code=COALESCE(error_code,'interrupted') "
            "WHERE status IN $_inFlight", [now]);
        final n = await txn.rawUpdate(
            "UPDATE campaign_recipients SET status='unknown', last_error_code='interrupted', updated_at=? "
            "WHERE status IN $_inFlight", [now]);
        await txn.rawUpdate(
            "UPDATE campaigns SET status='paused', updated_at=? WHERE status IN ('running','awaiting_user_action')",
            [now]);
        return n;
      });

  /// Manually settle an `unknown` recipient (e.g. the user checked the sent folder).
  Future<int?> resolveUnknown(int recipientId, RecipientStatus resolved) async {
    final a = await _db.query('send_attempts', where: 'campaign_recipient_id = ?',
        whereArgs: [recipientId], orderBy: 'attempt_number DESC', limit: 1);
    if (a.isEmpty) return null;
    return applyResult(a.first['id'] as int, resolved, errorCode: 'manually_resolved');
  }

  /// User-initiated retry. `failed`/`cancelled` can be re-queued directly; `unknown`
  /// may already have been delivered, so it needs explicit acknowledgement.
  Future<void> requeue(int recipientId, {bool acknowledgeDuplicateRisk = false}) =>
      _db.transaction((txn) async {
        final rows = await txn.query('campaign_recipients', where: 'id = ?', whereArgs: [recipientId]);
        if (rows.isEmpty) throw AttemptRefusedException('Recipient not found.');
        final st = recipientStatusFromDb(rows.first['status'] as String);
        if (st == RecipientStatus.unknown) {
          if (!acknowledgeDuplicateRisk) {
            throw AttemptRefusedException('This message may already have been sent. Confirm to risk a duplicate.');
          }
        } else if (!RecipientStateMachine.canTransition(st, RecipientStatus.pending)) {
          throw AttemptRefusedException('A ${st.name} message cannot be re-queued.');
        }
        await txn.update('campaign_recipients', {'status': 'pending', 'updated_at': _now()},
            where: 'id = ?', whereArgs: [recipientId]);
        await txn.rawUpdate(
            "UPDATE campaigns SET status='paused', updated_at=? WHERE id=? "
            "AND status IN ('completed','partially_completed','failed','cancelled')",
            [_now(), rows.first['campaign_id']]);
      });

  Future<void> markRunning(int campaignId) => _db.rawUpdate(
      "UPDATE campaigns SET status='running', started_at=COALESCE(started_at, ?), updated_at=? WHERE id=?",
      [_now(), _now(), campaignId]);

  Future<int> cancelPending(int campaignId) => _db.update('campaign_recipients',
      {'status': 'cancelled', 'updated_at': _now()},
      where: "campaign_id = ? AND status = 'pending'", whereArgs: [campaignId]);

  /// Recomputes campaign status from recipient statuses. Never overrides
  /// draft/ready/paused/cancelled. Returns the outcome if one is known.
  Future<CampaignStatus?> finalizeCampaign(int campaignId) async {
    final rows = await _db.query('campaigns', columns: ['status'], where: 'id = ?', whereArgs: [campaignId]);
    if (rows.isEmpty) return null;
    final cur = campaignStatusFromDb(rows.first['status'] as String);
    const finalizable = {CampaignStatus.running, CampaignStatus.awaitingUserAction,
        CampaignStatus.completed, CampaignStatus.partiallyCompleted, CampaignStatus.failed};
    if (!finalizable.contains(cur)) return null;
    final out = computeCampaignOutcome(await _counts(campaignId));
    if (out == null || out == cur) return out;
    final now = _now();
    await _db.rawUpdate("UPDATE campaigns SET status=?, completed_at=?, updated_at=? WHERE id=?",
        [out == CampaignStatus.partiallyCompleted ? 'partially_completed' : out.name, now, now, campaignId]);
    return out;
  }

  Future<Map<RecipientStatus, int>> _counts(int id) async {
    final rows = await _db.rawQuery(
        'SELECT status, COUNT(*) AS n FROM campaign_recipients WHERE campaign_id = ? GROUP BY status', [id]);
    return {for (final r in rows) recipientStatusFromDb(r['status'] as String): r['n'] as int};
  }
}
