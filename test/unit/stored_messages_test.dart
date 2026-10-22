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

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

/// Like Android as the default messaging app: each send returns its stored row id.
class StoringSms implements SmsCapabilityService {
  int nextRow = 500;
  @override Future<SmsCapabilities> getCapabilities() async => androidOk;
  @override Future<bool> requestRequiredPermissions() async => true;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => const Stream.empty();
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async =>
      SmsOperationResult(RecipientStatus.submitted, storedMessageId: nextRow++);
}

void main() {
  sqfliteFfiInit();

  test('campaign texts are linked to their stored rows, so conversations can label them', () async {
    final db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    addTearDown(db.close);
    final campaigns = CampaignRepository(db);
    final id = await campaigns.createDraft(name: 'Harvest Sunday', template: 'x', platform: 'android');
    await campaigns.saveSnapshot(id, const [
      SnapshotRecipient(name: 'Ada', phoneE164: '+1', renderedMessage: 'x'),
      SnapshotRecipient(name: 'Bola', phoneE164: '+2', renderedMessage: 'x'),
    ]);
    await SendOrchestrator(sms: StoringSms(), attempts: AttemptRepository(db), campaigns: campaigns, sleep: (_) async {})
        .runAndroid(id);
    final labels = await campaigns.campaignsForStoredMessages([500, 501, 999]);
    expect(labels.keys.toSet(), {500, 501});
    expect(labels[500], (campaignId: id, name: 'Harvest Sunday'));
    expect(await campaigns.campaignsForStoredMessages(const []), isEmpty);
  });
}
