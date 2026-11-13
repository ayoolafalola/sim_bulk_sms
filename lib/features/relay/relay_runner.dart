import 'package:sqflite/sqflite.dart';

import '../../data/repositories/campaign_repository.dart';
import '../../domain/services/campaign_planner.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../../platform/contacts_plus/contacts_plus_auth.dart';

/// Talks to Contacts++ for the phone relay. Abstract for tests.
abstract interface class RelayTransport {
  /// Claims the texts waiting for this phone.
  Future<List<RelayBatch>> claim();
  Future<void> report(List<Map<String, dynamic>> results);
}

class RelayJob {
  const RelayJob({required this.id, required this.to, required this.body, this.name});
  final String id, to, body;
  final String? name;
}

class RelayBatch {
  const RelayBatch({required this.id, required this.jobs, this.name, this.source = 'web'});
  final String id, source;
  final String? name;
  final List<RelayJob> jobs;
}

class ContactsRelayTransport implements RelayTransport {
  ContactsRelayTransport(this._auth);
  final ContactsPlusAuth _auth;

  @override
  Future<List<RelayBatch>> claim() async {
    final token = await _auth.accessToken();
    if (token == null) return const [];
    // "redelivery": claims of ours that never reported come back too (claim
    // below skips the ones this phone already holds).
    final data = (await _auth.api.post('/messages-plus/relay/claim', const {'redelivery': true}, token: token))['data'] as Map;
    return [
      for (final b in (data['batches'] as List).cast<Map>())
        RelayBatch(
          id: '${b['batch_id']}',
          name: b['name'] as String?,
          source: '${b['source'] ?? 'web'}',
          jobs: [
            for (final j in (b['jobs'] as List).cast<Map>())
              RelayJob(id: '${j['id']}', to: '${j['to']}', body: '${j['body']}', name: j['name'] as String?),
          ],
        ),
    ];
  }

  @override
  Future<void> report(List<Map<String, dynamic>> results) async {
    final token = await _auth.accessToken();
    if (token == null || results.isEmpty) return;
    await _auth.api.post('/messages-plus/relay/results', {'results': results}, token: token);
  }
}

/// Texts written on the web, sent from this phone.
///
/// Each claimed batch becomes an ordinary campaign ("From the web · …"), so
/// it goes through the same pipeline as a campaign made here: Contacts++
/// chats first, then the SIM, with the send limits, delays and opt-out list.
/// Opted-out numbers are never texted and are reported as `opted_out`.
class RelayRunner {
  RelayRunner({required this.db, required this.transport, required this.campaigns, String Function()? platform})
      : _platform = platform ?? (() => 'android');

  final Database db;
  final RelayTransport transport;
  final CampaignRepository campaigns;
  final String Function() _platform;

  /// Claims waiting texts and makes campaigns of them. Returns the new
  /// campaign ids (ready to send).
  Future<List<int>> claim() async {
    final List<RelayBatch> batches;
    try {
      batches = await transport.claim();
    } on ContactsPlusException {
      return const [];
    }
    final suppressed = {
      for (final r in await db.query('suppression_list')) r['phone_number_normalized'] as String,
      for (final r in await db.query('contacts', columns: ['phone_normalized'], where: "consent_status = 'opted_out'"))
        if (r['phone_normalized'] != null) r['phone_normalized'] as String,
    };
    // Texts this phone already holds (handed out again by the server because
    // their result wasn't reported yet): never a second campaign for them.
    final held = {for (final r in await db.query('relay_links', columns: ['job_id'])) r['job_id'] as String};
    final created = <int>[];
    final optedOut = <Map<String, dynamic>>[];
    for (final batch in batches) {
      final fresh = [
        for (final j in batch.jobs)
          if (!held.contains(j.id)) j
      ];
      final keep = [
        for (final j in fresh)
          if (!suppressed.contains(j.to)) j
      ];
      optedOut.addAll([
        for (final j in fresh)
          if (suppressed.contains(j.to)) {'id': j.id, 'status': 'opted_out', 'error_code': 'opted_out'},
      ]);
      if (keep.isEmpty) continue;
      final label = switch (batch.source) {
        'api' => 'API',
        'contacts' => 'Contacts++',
        _ => 'From the web',
      };
      final id = await campaigns.createDraft(
        name: batch.name == null || batch.name!.trim().isEmpty ? label : '$label · ${batch.name}',
        template: keep.first.body,
        platform: _platform(),
      );
      await campaigns.saveSnapshot(id, [
        for (final j in keep) SnapshotRecipient(name: j.name ?? j.to, phoneE164: j.to, renderedMessage: j.body),
      ]);
      // Link each job to its campaign row (saveSnapshot keeps the order).
      final rows = await db.query('campaign_recipients',
          columns: ['id'], where: 'campaign_id = ?', whereArgs: [id], orderBy: 'id');
      final now = DateTime.now().toUtc().toIso8601String();
      final b = db.batch();
      for (var i = 0; i < keep.length && i < rows.length; i++) {
        b.insert('relay_links', {'job_id': keep[i].id, 'campaign_recipient_id': rows[i]['id'], 'created_at': now},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await b.commit(noResult: true);
      created.add(id);
    }
    if (optedOut.isNotEmpty) {
      try {
        await transport.report(optedOut);
      } on ContactsPlusException {
        // Not linked locally, so not retried: the server expires them.
      }
    }
    return created;
  }

  /// Campaigns made from claimed texts that never started sending (the phone
  /// or app stopped in between). The server will not hand these texts out
  /// again, so they are sent from here.
  Future<List<int>> unstarted() async => [
        for (final r in await db.rawQuery('''
          SELECT DISTINCT c.id FROM relay_links l
          JOIN campaign_recipients r ON r.id = l.campaign_recipient_id
          JOIN campaigns c ON c.id = r.campaign_id
          WHERE c.status = 'ready' AND l.reported = 'claimed' ORDER BY c.id''')) r['id'] as int,
      ];

  /// Tells Contacts++ what happened to each text since the last report.
  Future<int> reportResults() async {
    final rows = await db.rawQuery('''
      SELECT l.job_id, l.reported, r.status, r.last_error_code,
        (SELECT a.platform FROM send_attempts a WHERE a.campaign_recipient_id = r.id
          ORDER BY a.attempt_number DESC LIMIT 1) AS platform
      FROM relay_links l JOIN campaign_recipients r ON r.id = l.campaign_recipient_id''');
    final results = <Map<String, dynamic>>[];
    for (final r in rows) {
      final status = switch (r['status']) {
        'sent' => 'sent',
        'delivered' => 'delivered',
        'failed' => 'failed',
        'cancelled' => 'cancelled',
        _ => null, // still on its way, or unknown until resolved
      };
      if (status == null || status == r['reported']) continue;
      // The server needs "sent" before "delivered".
      if (status == 'delivered' && r['reported'] == 'claimed') {
        results.add({'id': r['job_id'], 'status': 'sent', 'channel': _channel(r['platform'])});
      }
      results.add({
        'id': r['job_id'],
        'status': status,
        'channel': _channel(r['platform']),
        if (r['last_error_code'] != null && status == 'failed') 'error_code': '${r['last_error_code']}',
      });
    }
    if (results.isEmpty) return 0;
    for (var i = 0; i < results.length; i += 500) {
      await transport.report(results.sublist(i, (i + 500).clamp(0, results.length)));
    }
    final b = db.batch();
    for (final r in results) {
      b.update('relay_links', {'reported': r['status']}, where: 'job_id = ?', whereArgs: [r['id']]);
    }
    await b.commit(noResult: true);
    return results.length;
  }

  static String _channel(Object? platform) => platform == 'contacts_chat' ? 'chat' : 'sms';
}
