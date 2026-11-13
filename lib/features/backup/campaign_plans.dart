import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/pro.dart';
import '../../domain/models/schedule.dart';
import '../campaigns/campaign_composer.dart';

/// Campaigns made or edited on the web (or on another phone), synced as
/// `campaign_plan` records, and what this phone did with them, synced back as
/// `campaign_status` records under the same key.
///
/// A plan (`data`):
/// ```
/// { name, template, channel: 'sms',
///   audience: { groups: [groupKey], contacts: [contactKey] },
///   fallbacks: { variable: value },
///   schedule: null                                   // send now
///           | { kind: 'once', at: '<UTC ISO>' }
///           | { kind: 'weekly', weekdays: <bits, Monday = 1>, minute_of_day: <local>, ends_on: 'YYYY-MM-DD'|null },
///   enabled: true, updated_at: '<UTC ISO>' }
/// ```
///
/// Rules: the latest edit wins (web or phone, by `updated_at`); a campaign
/// that has started sending is locked, so later web edits are refused and the
/// status says so. A one-time send that came due while the phone was offline
/// goes as soon as the phone gets it, up to [catchUp] late.
class CampaignPlans {
  CampaignPlans({
    required this.db,
    required this.campaigns,
    required this.schedules,
    required this.composer,
    required this.platform,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Database db;
  final CampaignRepository campaigns;
  final ScheduleRepository schedules;
  final CampaignComposer composer;
  final String platform;
  final DateTime Function() _clock;

  static const planKind = 'campaign_plan';
  static const statusKind = 'campaign_status';
  static const catchUp = Duration(hours: 24);

  // ---- Remote → this phone ---------------------------------------------

  /// Applies one plan from elsewhere. Returns true when this phone changed.
  Future<bool> apply({required String key, required int seq, required bool deleted, Map<String, dynamic>? data}) async {
    final link = (await db.query('sync_links', where: 'kind = ? AND sync_key = ?', whereArgs: [planKind, key])).firstOrNull;
    if (link != null && (link['seq'] as int) >= seq) return false; // this phone's own upload
    int? localId = link?['local_id'] as int?;
    final existing = localId == null ? null : await campaigns.get(localId);
    if (existing == null) localId = null;

    if (deleted) {
      if (localId == null) return false;
      if (_editable(existing!.status.name)) await campaigns.delete(localId);
      await db.delete('sync_links', where: 'kind IN (?, ?) AND local_id = ?', whereArgs: [planKind, statusKind, localId]);
      return true;
    }
    final d = data ?? const <String, dynamic>{};
    final remoteAt = DateTime.tryParse('${d['updated_at'] ?? ''}');

    if (localId != null) {
      // Started sending: the plan is history now.
      if (!_editable(_statusDb(existing!))) {
        await _note(key, 'locked', 'Already sending or sent from your phone, so this change wasn’t applied.');
        await _link(planKind, localId, key, link?['hash'] as String?, seq);
        return false;
      }
      // Changed here since the last sync, and more recently than the web edit: keep this one.
      final mine = await record(localId);
      final localAt = await _localUpdatedAt(localId);
      if (mine != null && link?['hash'] != _hash(mine) && remoteAt != null && localAt != null && localAt.isAfter(remoteAt)) {
        await _link(planKind, localId, key, link?['hash'] as String?, seq);
        return false;
      }
    }

    final name = '${d['name'] ?? 'Campaign from the web'}'.trim();
    final template = '${d['template'] ?? ''}';
    final audienceData = (d['audience'] as Map?) ?? const {};
    final audience = CampaignAudience(
      groupIds: await _localIds('group', audienceData['groups']),
      contactIds: await _localIds('contact', audienceData['contacts']),
    );
    final fallbacks = {
      for (final e in ((d['fallbacks'] as Map?) ?? const {}).entries)
        if ('${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}',
    };

    String? problem;
    final plan = await composer.plan(template: template, groupIds: audience.groupIds, contactIds: audience.contactIds, fallbacks: fallbacks);
    int id;
    if (plan.canSave) {
      try {
        id = await composer.save(
            campaignId: localId, name: name, template: template, platform: platform, plan: plan,
            audience: audience, fallbacks: fallbacks);
      } on ProRequiredException catch (e) {
        await _note(key, 'needs_pro', e.message);
        if (localId == null) return false;
        id = localId;
      }
    } else {
      // Kept as a draft with its audience, so it can be fixed (here or on the web).
      if (localId == null) {
        id = await campaigns.createDraft(name: name, template: template, platform: platform, fallbacks: fallbacks);
      } else {
        id = localId;
        await campaigns.updateDraft(id, name: name, template: template);
        await campaigns.saveFallbacks(id, fallbacks);
      }
      await campaigns.saveAudience(id, audience);
      problem = plan.blocked.isNotEmpty
          ? 'Some people have no value for ${plan.unresolvedVariables.map((v) => '{$v}').join(', ')}. Add a fallback.'
          : 'No one in this campaign can get a text. Check its groups and people.';
    }

    final now = _clock();
    final spec = _spec(d['schedule'], now);
    if (spec == null) {
      final s = await schedules.forCampaign(id);
      if (s != null) await schedules.delete(s.id);
    } else {
      await schedules.save(id, spec, now: now);
      if (d['enabled'] == false) {
        final s = await schedules.forCampaign(id);
        if (s != null) await schedules.setEnabled(s.id, false, now: now);
      }
    }
    await _note(key, problem == null ? 'ok' : 'needs_attention', problem, applied: '${d['updated_at'] ?? ''}');
    final mine = await record(id);
    await _link(planKind, id, key, mine == null ? null : _hash(mine), seq);
    return true;
  }

  /// The schedule to save: "send now" and late one-time sends go at the
  /// start of the next minute (a schedule only runs at a time after it's saved).
  ScheduleSpec? _spec(Object? raw, DateTime now) {
    final soon = DateTime(now.year, now.month, now.day, now.hour, now.minute + 1);
    final s = raw is Map ? raw : null;
    if (s == null) return ScheduleSpec.once(soon);
    if (s['kind'] == 'weekly') {
      final weekdays = (s['weekdays'] as num?)?.toInt() ?? 0;
      final minute = (s['minute_of_day'] as num?)?.toInt();
      if (weekdays == 0 || minute == null) return null;
      return ScheduleSpec.weekly(weekdays: weekdays, minuteOfDay: minute, endsOn: DateTime.tryParse('${s['ends_on'] ?? ''}'));
    }
    final at = DateTime.tryParse('${s['at'] ?? ''}')?.toLocal();
    if (at == null) return ScheduleSpec.once(soon);
    if (!at.isAfter(now) && now.difference(at) <= catchUp) return ScheduleSpec.once(soon);
    return ScheduleSpec.once(at);
  }

  // ---- This phone → records ---------------------------------------------

  /// Plans to upload, by local campaign id: every campaign already linked to
  /// a plan, plus (with [includeNew], i.e. backup on) this phone's own saved
  /// campaigns that aren't scheduled-run copies.
  Future<Map<int, Map<String, dynamic>>> records({required bool includeNew}) async {
    final linked = {
      for (final l in await db.query('sync_links', columns: ['local_id'], where: 'kind = ?', whereArgs: [planKind])) l['local_id'] as int,
    };
    final rows = await db.query('campaigns',
        columns: ['id', 'status', 'schedule_id'], where: 'schedule_id IS NULL', orderBy: 'id');
    final out = <int, Map<String, dynamic>>{};
    for (final r in rows) {
      final id = r['id'] as int;
      final isNew = !linked.contains(id);
      if (isNew && (!includeNew || !_editable(r['status'] as String))) continue;
      final rec = await record(id);
      if (rec != null) out[id] = rec;
    }
    return out;
  }

  /// One campaign as a plan record (null if it no longer exists).
  Future<Map<String, dynamic>?> record(int id) async {
    final c = (await db.query('campaigns', where: 'id = ?', whereArgs: [id])).firstOrNull;
    if (c == null) return null;
    final audience = await campaigns.audience(id);
    final s = await schedules.forCampaign(id);
    return {
      'name': c['name'],
      'template': c['message_template'],
      'channel': c['channel'] ?? 'sms',
      'audience': {
        'groups': await _keys('group', audience.groupIds),
        'contacts': await _keys('contact', audience.contactIds),
      },
      'fallbacks': await campaigns.fallbacks(id),
      'schedule': s == null
          ? null
          : s.kind == ScheduleKind.once
              ? {'kind': 'once', 'at': s.runAt?.toUtc().toIso8601String()}
              : {
                  'kind': 'weekly',
                  'weekdays': s.weekdays,
                  'minute_of_day': s.minuteOfDay,
                  'ends_on': s.endsOn == null ? null : _date(s.endsOn!),
                },
      'enabled': s?.enabled ?? true,
      'updated_at': (await _localUpdatedAt(id))?.toUtc().toIso8601String(),
    };
  }

  /// What this phone did with each plan, keyed by local campaign id (the
  /// sync key is the plan's).
  Future<Map<int, Map<String, dynamic>>> statuses() async {
    final out = <int, Map<String, dynamic>>{};
    for (final l in await db.query('sync_links', where: 'kind = ?', whereArgs: [planKind])) {
      final id = l['local_id'] as int;
      final key = l['sync_key'] as String;
      final c = await campaigns.get(id);
      if (c == null) continue;
      final s = await schedules.forCampaign(id);
      final note = await _readNote(key);
      final runId = s?.kind == ScheduleKind.weekly ? s?.lastRunCampaignId : id;
      final run = runId == null ? null : await campaigns.get(runId);
      final counts = runId == null ? const <String, int>{} : await _counts(runId);
      final status = _statusDb(c);
      String state;
      String? message = note?['message'] as String?;
      if (note?['state'] == 'needs_pro') {
        state = 'needs_pro';
      } else if (status == 'running' || status == 'awaiting_user_action' || status == 'paused') {
        state = status == 'awaiting_user_action' ? 'needs_tap' : (status == 'paused' ? 'paused' : 'sending');
        if (state == 'needs_tap') message ??= 'Open Messages++ on your phone and tap Send.';
      } else if (status == 'completed' || status == 'partially_completed' || status == 'failed' || status == 'cancelled') {
        state = status == 'completed' ? 'sent' : status;
      } else if (status == 'draft') {
        state = 'needs_attention';
      } else if (s == null) {
        state = 'ready';
      } else if (!s.enabled) {
        state = 'paused';
      } else if (s.nextRunAt != null) {
        state = 'scheduled';
      } else {
        state = s.lastOutcome == ScheduleOutcome.missed ? 'missed' : 'done';
        if (state == 'missed') message ??= 'Missed: your phone was off or offline at that time.';
      }
      if (note?['state'] == 'locked' && state != 'needs_attention') message = note?['message'] as String?;
      out[id] = {
        'state': state,
        'message': message,
        'applied_updated_at': note?['applied'],
        'recipients': c.recipientCount,
        'next_run_at': s?.nextRunAt?.toUtc().toIso8601String(),
        'last_run_at': s?.lastRunAt?.toUtc().toIso8601String(),
        'last_outcome': s?.lastOutcome?.name,
        'last_run': run == null ? null : {'name': run.name, 'status': _statusDb(run), 'counts': counts},
        'platform': platform,
      };
    }
    return out;
  }

  /// The plan key for a local campaign, for the status upload.
  Future<String?> keyFor(int localId) async => (await db.query('sync_links',
          columns: ['sync_key'], where: 'kind = ? AND local_id = ?', whereArgs: [planKind, localId]))
      .firstOrNull?['sync_key'] as String?;

  // ---- Helpers -----------------------------------------------------------

  static bool _editable(String status) => status == 'draft' || status == 'ready';

  static String _statusDb(Campaign c) => switch (c.status.name) {
        'awaitingUserAction' => 'awaiting_user_action',
        'partiallyCompleted' => 'partially_completed',
        final s => s,
      };

  Future<Map<String, int>> _counts(int campaignId) async => {
        for (final r in await db.rawQuery(
            'SELECT status, COUNT(*) AS n FROM campaign_recipients WHERE campaign_id = ? GROUP BY status', [campaignId]))
          r['status'] as String: r['n'] as int,
      };

  Future<DateTime?> _localUpdatedAt(int id) async {
    final row = (await db.rawQuery('''
      SELECT c.updated_at AS c, s.updated_at AS s FROM campaigns c
      LEFT JOIN campaign_schedules s ON s.campaign_id = c.id WHERE c.id = ?''', [id])).firstOrNull;
    if (row == null) return null;
    final times = [DateTime.tryParse('${row['c'] ?? ''}'), DateTime.tryParse('${row['s'] ?? ''}')].whereType<DateTime>().toList()
      ..sort();
    return times.lastOrNull;
  }

  Future<Set<int>> _localIds(String kind, Object? keys) async {
    final list = [for (final k in (keys as List? ?? const [])) '$k'];
    if (list.isEmpty) return {};
    return {
      for (final row in await db.query('sync_links',
          columns: ['local_id'],
          where: 'kind = ? AND sync_key IN (${List.filled(list.length, '?').join(',')})',
          whereArgs: [kind, ...list]))
        row['local_id'] as int,
    };
  }

  Future<List<String>> _keys(String kind, Set<int> ids) async {
    if (ids.isEmpty) return const [];
    final list = ids.toList();
    return [
      for (final row in await db.query('sync_links',
          columns: ['sync_key'],
          where: 'kind = ? AND local_id IN (${List.filled(list.length, '?').join(',')})',
          whereArgs: [kind, ...list]))
        row['sync_key'] as String,
    ]..sort();
  }

  Future<void> _link(String kind, int localId, String key, String? hash, int seq) => db.insert(
      'sync_links', {'kind': kind, 'local_id': localId, 'sync_key': key, 'hash': hash, 'seq': seq},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _note(String key, String state, String? message, {String? applied}) async {
    final previous = await _readNote(key);
    await db.insert(
        'app_settings',
        {
          'key': 'cpp_plan_note:$key',
          'value': jsonEncode({'state': state, 'message': message, 'applied': applied ?? previous?['applied']}),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> _readNote(String key) async {
    final raw = (await db.query('app_settings', where: 'key = ?', whereArgs: ['cpp_plan_note:$key'])).firstOrNull?['value'] as String?;
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The hash that decides whether a plan changed: its content, not when.
  static String hashPlan(Map<String, dynamic> data) =>
      sha1.convert(utf8.encode(jsonEncode({...data}..remove('updated_at')))).toString();

  static String _hash(Map<String, dynamic> data) => hashPlan(data);

  /// After uploading this phone's version of a plan: the web shows it as
  /// already applied here (not "waiting for your phone").
  Future<void> markUploaded(String key, Map<String, dynamic> data) async {
    final previous = await _readNote(key);
    await db.insert(
        'app_settings',
        {
          'key': 'cpp_plan_note:$key',
          'value': jsonEncode({...?previous, 'applied': '${data['updated_at'] ?? ''}'}),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
