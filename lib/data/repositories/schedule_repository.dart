import 'package:sqflite/sqflite.dart';
import '../../domain/models/schedule.dart';
import '../../domain/services/schedule_calculator.dart';

String _now() => DateTime.now().toUtc().toIso8601String();
String _date(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
// Local wall-clock times are stored without a zone; instants (next/last run) as UTC.
String _local(DateTime d) => DateTime(d.year, d.month, d.day, d.hour, d.minute).toIso8601String();
/// UTC ISO with millisecond precision, so stored instants compare correctly as text.
String _utc(DateTime d) => DateTime.fromMillisecondsSinceEpoch(d.millisecondsSinceEpoch, isUtc: true).toIso8601String();
String? _utcOrNull(DateTime? d) => d == null ? null : _utc(d);
DateTime? _parse(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

/// A schedule plus the name of the campaign it belongs to (for lists).
class ScheduleListItem {
  const ScheduleListItem(this.schedule, this.campaignName);
  final CampaignSchedule schedule;
  final String campaignName;
}

class ScheduleRepository {
  ScheduleRepository(this._db);
  final Database _db;

  CampaignSchedule _fromRow(Map<String, Object?> r) => CampaignSchedule(
        id: r['id'] as int,
        campaignId: r['campaign_id'] as int,
        kind: r['kind'] == 'once' ? ScheduleKind.once : ScheduleKind.weekly,
        runAt: r['run_at'] == null ? null : DateTime.parse(r['run_at'] as String),
        weekdays: r['weekdays'] as int,
        minuteOfDay: r['minute_of_day'] as int?,
        endsOn: r['ends_on'] == null ? null : DateTime.parse(r['ends_on'] as String),
        enabled: r['enabled'] == 1,
        nextRunAt: _parse(r['next_run_at']),
        lastRunAt: _parse(r['last_run_at']),
        lastRunCampaignId: r['last_run_campaign_id'] as int?,
        lastOutcome: r['last_outcome'] == null
            ? null
            : ScheduleOutcome.values.firstWhere((o) => o.name == r['last_outcome'],
                orElse: () => ScheduleOutcome.needsAttention),
      );

  /// Creates or replaces the campaign's schedule (one per campaign) and
  /// computes its first run after [now]. Returns the schedule id.
  Future<int> save(int campaignId, ScheduleSpec spec, {required DateTime now}) async {
    final next = nextOccurrence(spec, now);
    final values = {
      'campaign_id': campaignId,
      'kind': spec.kind.name,
      'run_at': spec.runAt == null ? null : _local(spec.runAt!),
      'weekdays': spec.weekdays,
      'minute_of_day': spec.minuteOfDay,
      'ends_on': spec.endsOn == null ? null : _date(spec.endsOn!),
      'enabled': 1,
      'next_run_at': (next == null ? null : _utc(next)),
      'updated_at': _now(),
    };
    return _db.transaction((txn) async {
      final existing = await txn.query('campaign_schedules', columns: ['id'], where: 'campaign_id = ?', whereArgs: [campaignId]);
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as int;
        await txn.update('campaign_schedules', values, where: 'id = ?', whereArgs: [id]);
        return id;
      }
      return txn.insert('campaign_schedules', {...values, 'created_at': _now()});
    });
  }

  Future<CampaignSchedule?> forCampaign(int campaignId) async {
    final rows = await _db.query('campaign_schedules', where: 'campaign_id = ?', whereArgs: [campaignId]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<CampaignSchedule?> get(int id) async {
    final rows = await _db.query('campaign_schedules', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Enabled schedules first, soonest first.
  Future<List<ScheduleListItem>> list() async {
    final rows = await _db.rawQuery('''
      SELECT s.*, c.name AS campaign_name FROM campaign_schedules s JOIN campaigns c ON c.id = s.campaign_id
      ORDER BY s.enabled DESC, s.next_run_at IS NULL, s.next_run_at''');
    return rows.map((r) => ScheduleListItem(_fromRow(r), r['campaign_name'] as String)).toList();
  }

  /// Enabled schedules whose next run is at or before [now].
  Future<List<CampaignSchedule>> due(DateTime now) async {
    final rows = await _db.query('campaign_schedules',
        where: 'enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ?',
        whereArgs: [_utc(now)], orderBy: 'next_run_at');
    return rows.map(_fromRow).toList();
  }

  /// Earliest upcoming run of any enabled schedule (the next time to wake up).
  Future<DateTime?> nextWake() async {
    final rows = await _db.rawQuery(
        'SELECT MIN(next_run_at) AS t FROM campaign_schedules WHERE enabled = 1 AND next_run_at IS NOT NULL');
    return _parse(rows.first['t']);
  }

  /// Pausing keeps the schedule; resuming recomputes the next run from [now]
  /// (occurrences while paused are not sent).
  Future<void> setEnabled(int id, bool enabled, {required DateTime now}) async {
    final s = await get(id);
    if (s == null) return;
    await _db.update('campaign_schedules', {
      'enabled': enabled ? 1 : 0,
      if (enabled) 'next_run_at': _utcOrNull(nextOccurrence(specOf(s), now)),
      'updated_at': _now(),
    }, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(int id) => _db.delete('campaign_schedules', where: 'id = ?', whereArgs: [id]);

  /// Records what happened for the occurrence due at [dueAt] and advances to
  /// the next occurrence after [now]. A one-time schedule is switched off.
  Future<void> recordRun(CampaignSchedule s, {required DateTime now, required ScheduleOutcome outcome, int? runCampaignId}) async {
    final next = nextOccurrence(specOf(s), now);
    await _db.update('campaign_schedules', {
      'last_run_at': _utc(now),
      'last_outcome': outcome.name,
      if (runCampaignId != null) 'last_run_campaign_id': runCampaignId,
      'next_run_at': (next == null ? null : _utc(next)),
      if (next == null) 'enabled': 0,
      'updated_at': _now(),
    }, where: 'id = ?', whereArgs: [s.id]);
  }
}
