import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/attempt_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/features/setup/setup_status.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/background/background_send_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

void main() {
  sqfliteFfiInit();

  group('SetupStatus', () {
    test('nothing granted: the four required items are missing, contacts is not', () {
      final s = SetupStatus.fromAndroid(nothingGranted);
      expect(s.missingRequired,
          [SetupItem.notifications, SetupItem.sms, SetupItem.exactAlarms, SetupItem.battery]); // notifications first
      expect(s.complete, false);
      expect(s.isRequired(SetupItem.contacts), false);
    });
    test('everything granted: complete', () => expect(SetupStatus.fromAndroid(everythingGranted).complete, true));
    test('notifications granted only by the default-app role are not counted until the user confirms', () {
      const roleOnly = BackgroundStatus(notifications: true, notificationsConfirmed: false, exactAlarms: true,
          batteryUnrestricted: true, serviceRunning: false, defaultSms: true);
      final s = SetupStatus.fromAndroid(roleOnly);
      expect(s.isOk(SetupItem.notifications), false);
      expect(s.opensSettings(SetupItem.notifications), true);
      expect(s.notes[SetupItem.notifications], contains('default messaging app'));
    });
    test('"Messages" notifications turned off counts as missing', () {
      const channelOff = BackgroundStatus(notifications: true, messageNotificationsOff: true, exactAlarms: true,
          batteryUnrestricted: true, serviceRunning: false, defaultSms: true);
      final s = SetupStatus.fromAndroid(channelOff);
      expect(s.missingRequired, [SetupItem.notifications]);
      expect(s.notes[SetupItem.notifications], contains('"Messages" notifications are turned off'));
    });
    test('contacts missing alone does not count as incomplete', () {
      final s = SetupStatus.fromAndroid(const BackgroundStatus(notifications: true, exactAlarms: true,
          batteryUnrestricted: true, serviceRunning: false, sms: true, contacts: false));
      expect(s.complete, true);
    });
    test('no telephony (tablet): no SMS item at all', () {
      final s = SetupStatus.fromAndroid(const BackgroundStatus(notifications: true, exactAlarms: true,
          batteryUnrestricted: true, serviceRunning: false, telephony: false, sms: false));
      expect(s.items, isNot(contains(SetupItem.sms)));
      expect(s.complete, true);
    });
    test('store build: only reminders matter; no SMS or battery items', () {
      final s = SetupStatus.fromAndroid(nothingGranted, store: true);
      expect(s.items, [SetupItem.notifications, SetupItem.exactAlarms, SetupItem.contacts]);
      expect(s.missingRequired, [SetupItem.notifications, SetupItem.exactAlarms]);
      expect(SetupStatus.fromAndroid(const BackgroundStatus(notifications: true, exactAlarms: true,
          batteryUnrestricted: false, serviceRunning: false, sms: false), store: true).complete, true);
    });
    test('refused for good is remembered per item', () {
      final s = SetupStatus.fromAndroid(const BackgroundStatus(notifications: true, exactAlarms: true,
          batteryUnrestricted: true, serviceRunning: false, sms: false, smsPermanentlyDenied: true));
      expect(s.permanentlyDenied, {SetupItem.sms});
    });
  });

  group('settings flags', () {
    test('onboarding_done defaults to false and is remembered', () async {
      final db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      addTearDown(db.close);
      final r = SettingsRepository(db);
      expect(await r.flag('onboarding_done'), false);
      await r.setFlag('onboarding_done', true);
      expect(await r.flag('onboarding_done'), true);
    });
  });

  group('Messages-app fallback queue', () {
    late Database db;
    late CampaignRepository campaigns;
    late SendOrchestrator orch;
    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      campaigns = CampaignRepository(db);
      orch = SendOrchestrator(sms: FakeSmsService(androidFallback), attempts: AttemptRepository(db), campaigns: campaigns);
    });
    tearDown(() => db.close());

    Future<int> campaign(int n) async {
      final id = await campaigns.createDraft(name: 'C', template: 'x', platform: 'android');
      await campaigns.saveSnapshot(id, [
        for (var i = 1; i <= n; i++) SnapshotRecipient(name: 'R$i', phoneE164: '+100$i', renderedMessage: 'Hi R$i'),
      ]);
      return id;
    }

    test('one at a time: waits for you, then records your answer', () async {
      final id = await campaign(2);
      final m1 = (await orch.startManualSend(id))!;
      expect((m1.name, m1.phone, m1.body, m1.position, m1.total), ('R1', '+1001', 'Hi R1', 1, 2));
      expect((await campaigns.get(id))!.status, CampaignStatus.awaitingUserAction);
      expect((await campaigns.statusCounts(id))[RecipientStatus.awaitingUserAction], 1);

      await orch.finishManualSend(m1.attemptId, sent: true);
      final m2 = (await orch.startManualSend(id))!;
      expect(m2.position, 2);
      await orch.finishManualSend(m2.attemptId, sent: false);

      expect(await campaigns.statusCounts(id), {RecipientStatus.sent: 1, RecipientStatus.cancelled: 1});
      expect((await campaigns.get(id))!.status, CampaignStatus.partiallyCompleted);
      expect(await orch.startManualSend(id), isNull);
      final err = await db.query('campaign_recipients', columns: ['last_error_code'], where: "status = 'sent'");
      expect(err.single['last_error_code'], 'user_confirmed');
    });

    test('everyone confirmed: completed', () async {
      final id = await campaign(1);
      await orch.finishManualSend((await orch.startManualSend(id))!.attemptId, sent: true);
      expect((await campaigns.get(id))!.status, CampaignStatus.completed);
    });

    test('a "Not sent" recipient can be sent again later', () async {
      final id = await campaign(1);
      final m = (await orch.startManualSend(id))!;
      await orch.finishManualSend(m.attemptId, sent: false, errorCode: 'no_messages_app');
      final r = (await campaigns.recipients(id)).single;
      await AttemptRepository(db).requeue(r.id);
      final again = (await orch.startManualSend(id))!;
      expect(again.name, 'R1');
    });
  });
}
