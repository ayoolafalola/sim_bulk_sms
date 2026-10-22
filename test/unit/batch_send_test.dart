import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/attempt_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class NoSms implements SmsCapabilityService {
  @override Future<SmsCapabilities> getCapabilities() async => const SmsCapabilities(platform: SmsPlatform.android,
      canSendDirectly: false, usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.notDefaultApp);
  @override Future<bool> requestRequiredPermissions() async => false;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => const Stream.empty();
  @override Future<SmsOperationResult> sendMessage(SmsSendRequest r) => throw UnimplementedError();
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late CampaignRepository campaigns;
  late SendOrchestrator orch;

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    campaigns = CampaignRepository(db);
    orch = SendOrchestrator(sms: NoSms(), attempts: AttemptRepository(db), campaigns: campaigns);
  });
  tearDown(() => db.close());

  test('45 people with the same text go in batches of 20, 20 and 5', () async {
    final id = await campaigns.createDraft(name: 'C', template: 'x', platform: 'android');
    await campaigns.saveSnapshot(id, [
      for (var i = 0; i < 45; i++) SnapshotRecipient(name: 'P$i', phoneE164: '+1$i', renderedMessage: 'Same'),
    ]);
    expect(await orch.canBatch(id), true);
    final sizes = <String>[];
    while (true) {
      final b = await orch.startManualBatch(id);
      if (b == null) break;
      sizes.add('${b.from}-${b.to}');
      await orch.finishManualBatch(b.attemptIds, sent: b.from != 21); // the second batch "not sent"
    }
    expect(sizes, ['1-20', '21-40', '41-45']);
    final n = await campaigns.statusCounts(id);
    expect((n[RecipientStatus.sent], n[RecipientStatus.cancelled]), (25, 20));
  });

  test('personalised texts can\'t be batched', () async {
    final id = await campaigns.createDraft(name: 'C', template: 'Hi {first_name}', platform: 'android');
    await campaigns.saveSnapshot(id, const [
      SnapshotRecipient(name: 'Ada', phoneE164: '+11', renderedMessage: 'Hi Ada'),
      SnapshotRecipient(name: 'Bola', phoneE164: '+12', renderedMessage: 'Hi Bola'),
    ]);
    expect(await orch.canBatch(id), false);
  });
}
