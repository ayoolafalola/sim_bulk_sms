import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/attempt_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_outcome.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);
const androidBlocked = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.playPolicyUnresolved);
const iosOk = SmsCapabilities(platform: SmsPlatform.ios, canSendDirectly: false,
    usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.none);

class FakeSms implements SmsCapabilityService {
  FakeSms(this.caps);
  SmsCapabilities caps;
  final controller = StreamController<SmsEvent>.broadcast();
  final sentTo = <String>[];
  Future<SmsOperationResult> Function(SmsSendRequest)? onSend;

  @override Future<SmsCapabilities> getCapabilities() async => caps;
  @override Future<bool> requestRequiredPermissions() async => true;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => controller.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) {
    sentTo.add(r.phoneE164);
    return onSend != null ? onSend!(r) : Future.value(const SmsOperationResult(RecipientStatus.submitted));
  }
  void emit(String type, SmsSendRequest r, {String? code}) => controller.add(
      SmsEvent(type: type, campaignRecipientId: r.campaignRecipientId, attemptId: r.attemptId, errorCode: code));
}

void main() {
  sqfliteFfiInit();
  late Database db;
  late CampaignRepository campaigns;
  late AttemptRepository attempts;
  late FakeSms sms;
  late SendOrchestrator orch;

  Future<int> makeCampaign(int n, {String platform = 'android'}) async {
    final id = await campaigns.createDraft(name: 'C', template: 'x', platform: platform);
    await campaigns.saveSnapshot(id, [for (var i = 1; i <= n; i++)
      SnapshotRecipient(name: 'R$i', phoneE164: '+100$i', renderedMessage: 'x')]);
    return id;
  }
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await orch.flushEvents();
  }
  Future<Map<RecipientStatus, int>> counts(int id) => campaigns.statusCounts(id);

  void build(SmsCapabilities caps) {
    sms = FakeSms(caps);
    orch = SendOrchestrator(sms: sms, attempts: attempts, campaigns: campaigns, sleep: (_) async {})..start();
  }

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    campaigns = CampaignRepository(db);
    attempts = AttemptRepository(db);
    build(androidOk);
  });
  tearDown(() async { await orch.dispose(); await db.close(); });

  group('computeCampaignOutcome', () {
    test('in flight -> null', () => expect(computeCampaignOutcome({RecipientStatus.pending: 1, RecipientStatus.sent: 2}), isNull));
    test('all sent/delivered -> completed', () =>
        expect(computeCampaignOutcome({RecipientStatus.sent: 1, RecipientStatus.delivered: 1}), CampaignStatus.completed));
    test('mixed -> partiallyCompleted', () =>
        expect(computeCampaignOutcome({RecipientStatus.sent: 1, RecipientStatus.failed: 1}), CampaignStatus.partiallyCompleted));
    test('all failed -> failed', () => expect(computeCampaignOutcome({RecipientStatus.failed: 2}), CampaignStatus.failed));
    test('all unknown is NOT reported as failed', () =>
        expect(computeCampaignOutcome({RecipientStatus.unknown: 2}), CampaignStatus.partiallyCompleted));
    test('all cancelled -> cancelled', () => expect(computeCampaignOutcome({RecipientStatus.cancelled: 2}), CampaignStatus.cancelled));
  });

  group('Android run', () {
    test('sent and delivered come only from callbacks', () async {
      final id = await makeCampaign(3);
      final reqs = <SmsSendRequest>[];
      sms.onSend = (r) async {
        reqs.add(r);
        sms.emit('sendSucceeded', r);
        if (reqs.length == 1) sms.emit('deliveryReported', r);
        return const SmsOperationResult(RecipientStatus.submitted);
      };
      await orch.runAndroid(id);
      await settle();
      expect(await counts(id), {RecipientStatus.delivered: 1, RecipientStatus.sent: 2});
      expect((await campaigns.get(id))!.status, CampaignStatus.completed);
    });

    test('without callbacks recipients stay submitted and the campaign is not completed', () async {
      final id = await makeCampaign(2);
      await orch.runAndroid(id);
      await settle();
      expect(await counts(id), {RecipientStatus.submitted: 2});
      expect((await campaigns.get(id))!.status, CampaignStatus.running);
    });

    test('failure callback recorded; campaign partially completed', () async {
      final id = await makeCampaign(2);
      var i = 0;
      sms.onSend = (r) async {
        i++;
        sms.emit(i == 1 ? 'sendSucceeded' : 'sendFailed', r, code: i == 1 ? null : 'no_service');
        return const SmsOperationResult(RecipientStatus.submitted);
      };
      await orch.runAndroid(id);
      await settle();
      expect(await counts(id), {RecipientStatus.sent: 1, RecipientStatus.failed: 1});
      expect((await campaigns.get(id))!.status, CampaignStatus.partiallyCompleted);
      expect((await campaigns.recipients(id)).last.status, RecipientStatus.failed);
    });

    test('blocked build sends nothing and changes nothing', () async {
      final id = await makeCampaign(2);
      sms.caps = androidBlocked;
      await expectLater(orch.runAndroid(id), throwsA(isA<SendBlockedException>()));
      expect(sms.sentTo, isEmpty);
      expect(await counts(id), {RecipientStatus.pending: 2});
      expect((await campaigns.get(id))!.status, CampaignStatus.ready);
    });

    test('draft campaigns cannot be sent', () async {
      final id = await campaigns.createDraft(name: 'D', template: 't', platform: 'android');
      await expectLater(orch.runAndroid(id), throwsStateError);
    });

    test('second concurrent run is rejected', () async {
      final id = await makeCampaign(2);
      final hold = Completer<SmsOperationResult>();
      sms.onSend = (_) => hold.future;
      final first = orch.runAndroid(id);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(orch.runAndroid(id), throwsStateError);
      hold.complete(const SmsOperationResult(RecipientStatus.submitted));
      sms.onSend = null;
      await first;
    });

    test('pause stops after the current message', () async {
      final id = await makeCampaign(3);
      sms.onSend = (r) async { orch.pause(); return const SmsOperationResult(RecipientStatus.submitted); };
      await orch.runAndroid(id);
      expect(sms.sentTo.length, 1);
      expect((await campaigns.get(id))!.status, CampaignStatus.paused);
      expect((await counts(id))[RecipientStatus.pending], 2);
    });

    test('unavailable SIM halts the run without sending to the rest', () async {
      final id = await makeCampaign(3);
      sms.onSend = (_) async => const SmsOperationResult(RecipientStatus.failed, errorCode: 'subscription_unavailable');
      await orch.runAndroid(id, subscriptionId: 7);
      expect(sms.sentTo.length, 1);
      expect((await counts(id))[RecipientStatus.pending], 2);
      expect((await campaigns.get(id))!.status, CampaignStatus.paused);
    });

    test('cancel marks pending recipients cancelled', () async {
      final id = await makeCampaign(3);
      await orch.cancel(id);
      expect(await counts(id), {RecipientStatus.cancelled: 3});
      expect((await campaigns.get(id))!.status, CampaignStatus.cancelled);
    });
  });

  group('recovery and idempotency', () {
    test('after a crash the in-flight recipient is unknown and is NOT sent again', () async {
      final id = await makeCampaign(2);
      final first = (await attempts.nextPending(id))!;
      final a = await attempts.beginAttempt(first.id, 'android');
      await attempts.applyResult(a, RecipientStatus.submitted);
      await attempts.markRunning(id);
      // --- app killed here; next launch: ---
      expect(await attempts.recoverInterrupted(), 1);
      expect((await campaigns.get(id))!.status, CampaignStatus.paused);
      await orch.runAndroid(id);
      expect(sms.sentTo, ['+1002']); // only the untouched recipient
      expect((await campaigns.recipients(id)).first.status, RecipientStatus.unknown);
    });

    test('duplicate and late callbacks are ignored', () async {
      final id = await makeCampaign(1);
      final r = (await attempts.nextPending(id))!;
      final a = await attempts.beginAttempt(r.id, 'android');
      await attempts.applyResult(a, RecipientStatus.submitted);
      expect(await attempts.applyResult(a, RecipientStatus.sent), id);
      expect(await attempts.applyResult(a, RecipientStatus.sent), isNull);      // duplicate
      expect(await attempts.applyResult(a, RecipientStatus.delivered), id);
      expect(await attempts.applyResult(a, RecipientStatus.failed), isNull);    // late, contradicts delivered
      expect((await campaigns.recipients(id)).single.status, RecipientStatus.delivered);
    });

    test('a recipient that already has an attempt cannot start another', () async {
      final id = await makeCampaign(1);
      final r = (await attempts.nextPending(id))!;
      await attempts.beginAttempt(r.id, 'android');
      await expectLater(attempts.beginAttempt(r.id, 'android'), throwsA(isA<AttemptRefusedException>()));
    });

    test('retrying an unknown recipient requires acknowledging duplicate risk', () async {
      final id = await makeCampaign(1);
      final r = (await attempts.nextPending(id))!;
      final a = await attempts.beginAttempt(r.id, 'android');
      await attempts.applyResult(a, RecipientStatus.submitted);
      await attempts.recoverInterrupted();
      await expectLater(attempts.requeue(r.id), throwsA(isA<AttemptRefusedException>()));
      await attempts.requeue(r.id, acknowledgeDuplicateRisk: true);
      expect((await campaigns.recipients(id)).single.status, RecipientStatus.pending);
    });

    test('unknown can be resolved manually, and a delivered message cannot be re-queued', () async {
      final id = await makeCampaign(1);
      final r = (await attempts.nextPending(id))!;
      final a = await attempts.beginAttempt(r.id, 'android');
      await attempts.applyResult(a, RecipientStatus.submitted);
      await attempts.recoverInterrupted();
      await attempts.resolveUnknown(r.id, RecipientStatus.delivered);
      expect((await campaigns.recipients(id)).single.status, RecipientStatus.delivered);
      await expectLater(attempts.requeue(r.id), throwsA(isA<AttemptRefusedException>()));
    });

    test('attempt numbers increase on retry', () async {
      final id = await makeCampaign(1);
      final r = (await attempts.nextPending(id))!;
      final a1 = await attempts.beginAttempt(r.id, 'android');
      await attempts.applyResult(a1, RecipientStatus.submitted);
      await attempts.applyResult(a1, RecipientStatus.failed, errorCode: 'no_service');
      await attempts.requeue(r.id);
      await attempts.beginAttempt(r.id, 'android');
      final rows = await db.query('send_attempts', orderBy: 'attempt_number');
      expect(rows.map((x) => x['attempt_number']), [1, 2]);
      expect((await campaigns.recipients(id)).single.attemptCount, 2);
    });
  });

  group('iOS composer', () {
    setUp(() async { await orch.dispose(); build(iosOk); });

    test('cancel is never recorded as sent; nothing advances automatically', () async {
      final id = await makeCampaign(2, platform: 'ios');
      sms.onSend = (_) async => const SmsOperationResult(RecipientStatus.cancelled);
      expect(await orch.sendNextViaComposer(id), RecipientStatus.cancelled);
      expect(sms.sentTo.length, 1);
      expect(await counts(id), {RecipientStatus.cancelled: 1, RecipientStatus.pending: 1});
      expect((await campaigns.get(id))!.status, CampaignStatus.awaitingUserAction);
    });

    test('sent via composer is recorded as sent (not delivered); campaign completes after the last', () async {
      final id = await makeCampaign(2, platform: 'ios');
      sms.onSend = (_) async => const SmsOperationResult(RecipientStatus.sent);
      await orch.sendNextViaComposer(id);
      await orch.sendNextViaComposer(id);
      expect(await counts(id), {RecipientStatus.sent: 2});
      expect((await campaigns.get(id))!.status, CampaignStatus.completed);
      expect(await orch.sendNextViaComposer(id), isNull);
    });

    test('cancelled recipient can be re-queued and sent later', () async {
      final id = await makeCampaign(1, platform: 'ios');
      sms.onSend = (_) async => const SmsOperationResult(RecipientStatus.cancelled);
      await orch.sendNextViaComposer(id);
      final r = (await campaigns.recipients(id)).single;
      await attempts.requeue(r.id);
      sms.onSend = (_) async => const SmsOperationResult(RecipientStatus.sent);
      expect(await orch.sendNextViaComposer(id), RecipientStatus.sent);
    });

    test('unavailable composer blocks', () async {
      final id = await makeCampaign(1, platform: 'ios');
      sms.caps = const SmsCapabilities(platform: SmsPlatform.ios, canSendDirectly: false,
          usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);
      await expectLater(orch.sendNextViaComposer(id), throwsA(isA<SendBlockedException>()));
      expect(sms.sentTo, isEmpty);
    });
  });
}
