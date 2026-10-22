import 'dart:async';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/platform/background/background_send_service.dart';
import 'package:sim_bulk_sms/platform/sms/messages_app.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';

/// Background/setup bridge with a mutable permission state.
class FakeBackground implements BackgroundSendService {
  FakeBackground(this.current);
  BackgroundStatus current;
  final opened = <String>[];
  @override Future<bool> startSend(int campaignId, {int? subscriptionId}) async => true;
  @override Future<bool> checkNow() async => true;
  @override Future<bool> scheduleWake(DateTime? at) async => current.exactAlarms;
  @override Future<BackgroundStatus> status() async => current;
  @override
  Future<bool> requestNotifications() async {
    current = copy(current, notifications: true);
    return true;
  }
  @override Future<void> openNotificationSettings() async => opened.add('notifications');
  @override Future<void> openExactAlarmSettings() async => opened.add('alarms');
  @override Future<void> openBatterySettings() async => opened.add('battery');
  @override Future<void> openAppSettings() async => opened.add('app');

  static BackgroundStatus copy(BackgroundStatus s, {bool? sms, bool? notifications}) => BackgroundStatus(
        notifications: notifications ?? s.notifications, exactAlarms: s.exactAlarms,
        batteryUnrestricted: s.batteryUnrestricted, serviceRunning: s.serviceRunning, telephony: s.telephony,
        sms: sms ?? s.sms, smsPermanentlyDenied: s.smsPermanentlyDenied, contacts: s.contacts,
        contactsPermanentlyDenied: s.contactsPermanentlyDenied,
      );
}

const nothingGranted = BackgroundStatus(
    notifications: false, exactAlarms: false, batteryUnrestricted: false, serviceRunning: false,
    sms: false, contacts: false);
const everythingGranted = BackgroundStatus(
    notifications: true, exactAlarms: true, batteryUnrestricted: true, serviceRunning: false,
    sms: true, contacts: true);

/// SMS service whose permission prompt grants SMS in [bg].
class FakeSmsService implements SmsCapabilityService {
  FakeSmsService(this.caps, {this.bg});
  SmsCapabilities caps;
  final FakeBackground? bg;
  final controller = StreamController<SmsEvent>.broadcast();
  @override Future<SmsCapabilities> getCapabilities() async => caps;
  @override
  Future<bool> requestRequiredPermissions() async {
    if (bg != null) bg!.current = FakeBackground.copy(bg!.current, sms: true);
    return true;
  }
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => controller.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async => const SmsOperationResult(RecipientStatus.submitted);
}

class FakeMessagesApp implements MessagesApp {
  FakeMessagesApp({this.available = true});
  final bool available;
  final opened = <(String, String)>[];
  @override
  Future<bool> open(String phone, String body) async {
    if (available) opened.add((phone, body));
    return available;
  }
}

const androidFallback = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false,
    usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.permissionDenied,
    messageForUser: 'SMS permission is off. Messages open in your Messages app instead, one tap each.');
