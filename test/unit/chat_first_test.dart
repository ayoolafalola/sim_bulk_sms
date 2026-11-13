import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/attempt_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/contacts_plus/contacts_chat_service.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _android = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);
const _androidBlocked = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.playPolicyUnresolved);

class _Sms implements SmsCapabilityService {
  _Sms(this.caps);
  SmsCapabilities caps;
  final sentTo = <String>[];
  final _events = StreamController<SmsEvent>.broadcast();
  @override Future<SmsCapabilities> getCapabilities() async => caps;
  @override Future<bool> requestRequiredPermissions() async => true;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => _events.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async {
    sentTo.add(r.phoneE164);
    return const SmsOperationResult(RecipientStatus.submitted);
  }
}

class _Chats implements ChatSender {
  _Chats(this.members);
  final Map<String, String> members; // phone → user id
  final outcomes = <String, ChatOutcome>{};
  final sent = <({String userId, String body, String clientId})>[];

  @override
  Future<Map<String, ChatTarget?>> reachability(Iterable<String> numbers) async =>
      {for (final n in numbers) n: members[n] == null ? null : ChatTarget(userId: members[n]!)};

  @override
  Future<({ChatOutcome outcome, String? conversationId, String? error})> send(ChatTarget target, String body,
      {required String clientId}) async {
    sent.add((userId: target.userId, body: body, clientId: clientId));
    final outcome = outcomes[target.userId] ?? ChatOutcome.sent;
    return (outcome: outcome, conversationId: 'c-${target.userId}', error: outcome == ChatOutcome.sent ? null : 'x');
  }
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late CampaignRepository campaigns;
  late AttemptRepository attempts;
  late _Sms sms;
  late _Chats chats;
  var chatFirst = true;

  SendOrchestrator orchestrator() => SendOrchestrator(
      sms: sms, attempts: attempts, campaigns: campaigns, sleep: (_) async {},
      chats: chats, chatFirstEnabled: () async => chatFirst);

  Future<int> campaign(List<String> phones) async {
    final id = await campaigns.createDraft(name: 'Choir', template: 'Practice at 6', platform: 'android');
    await campaigns.saveSnapshot(id, [
      for (final p in phones) SnapshotRecipient(name: p, phoneE164: p, renderedMessage: 'Practice at 6'),
    ]);
    return id;
  }

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    campaigns = CampaignRepository(db);
    attempts = AttemptRepository(db);
    sms = _Sms(_android);
    chats = _Chats({'+2348031111111': 'u-bola'});
    chatFirst = true;
  });
  tearDown(() => db.close());

  test('Contacts++ members get a chat; everyone else gets a text', () async {
    final id = await campaign(['+2348031111111', '+2348032222222']);

    await orchestrator().runAndroid(id);

    expect(chats.sent.single.userId, 'u-bola');
    expect(sms.sentTo, ['+2348032222222']);
    final attempt = (await db.query('send_attempts', where: "platform = 'contacts_chat'")).single;
    expect(attempt['status'], 'sent');
    expect(attempt['native_operation_id'], chats.sent.single.clientId);
  });

  test('a campaign of members only completes without the SIM, even where texting is blocked', () async {
    sms.caps = _androidBlocked;
    final id = await campaign(['+2348031111111']);

    await orchestrator().runAndroid(id);

    expect(sms.sentTo, isEmpty);
    expect((await campaigns.get(id))!.status, CampaignStatus.completed);
  });

  test('a chat Contacts++ refuses goes as a text instead', () async {
    chats.outcomes['u-bola'] = ChatOutcome.refused;
    final id = await campaign(['+2348031111111']);

    await orchestrator().runAndroid(id);

    expect(sms.sentTo, ['+2348031111111']);
    final rows = await db.query('send_attempts', orderBy: 'attempt_number');
    expect([for (final r in rows) r['platform']], ['contacts_chat', 'android']);
    expect(rows.first['error_code'], 'chat_refused');
  });

  test('no answer from Contacts++ is never followed by an automatic text', () async {
    chats.outcomes['u-bola'] = ChatOutcome.uncertain;
    final id = await campaign(['+2348031111111']);

    await orchestrator().runAndroid(id);

    expect(sms.sentTo, isEmpty);
    expect((await campaigns.recipients(id)).single.status, RecipientStatus.unknown);
  });

  test('turning "chat first" off sends texts only', () async {
    chatFirst = false;
    final id = await campaign(['+2348031111111']);

    await orchestrator().runAndroid(id);

    expect(chats.sent, isEmpty);
    expect(sms.sentTo, ['+2348031111111']);
  });

  test('client ids are random version-4 UUIDs (the server ignores retried ones)', () {
    final a = ContactsChatService.newClientId(), b = ContactsChatService.newClientId();
    expect(a, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(a, isNot(b));
  });
}
