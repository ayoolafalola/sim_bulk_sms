import 'package:flutter/services.dart';

/// What the phone allows for background sending (Android).
class BackgroundStatus {
  const BackgroundStatus({
    required this.notifications, required this.exactAlarms,
    required this.batteryUnrestricted, required this.serviceRunning,
    this.telephony = true, this.sms = true, this.smsPermanentlyDenied = false,
    this.contacts = true, this.contactsPermanentlyDenied = false, this.notificationsPermanentlyDenied = false,
  });
  final bool notifications, exactAlarms, batteryUnrestricted, serviceRunning;
  /// The phone can send SMS at all (false on Wi-Fi-only tablets).
  final bool telephony;
  final bool sms, contacts;
  /// Refused for good: Android no longer shows the prompt; only app settings can turn it on.
  final bool smsPermanentlyDenied, contactsPermanentlyDenied, notificationsPermanentlyDenied;
  bool get ready => notifications && exactAlarms && batteryUnrestricted;
}

/// App-screen side: hand sends to the Android foreground service, set the
/// schedule wake-up, and read/fix the settings it needs.
abstract class BackgroundSendService {
  Future<bool> startSend(int campaignId, {int? subscriptionId});
  /// Starts the service to run any due schedules.
  Future<bool> checkNow();
  /// Sets (or clears) the wake-up for the next scheduled run. Returns false
  /// when exact alarms aren't allowed (runs then only start with the app open).
  Future<bool> scheduleWake(DateTime? at);
  Future<BackgroundStatus> status();
  Future<bool> requestNotifications();
  Future<void> openNotificationSettings();
  Future<void> openExactAlarmSettings();
  Future<void> openBatterySettings();
  Future<void> openAppSettings();
}

class NativeBackgroundSendService implements BackgroundSendService {
  static const _ch = MethodChannel('app.sim_bulk_sms/background');

  @override
  Future<bool> startSend(int campaignId, {int? subscriptionId}) async =>
      await _ch.invokeMethod<bool>('startSend', {'campaignId': campaignId, 'subscriptionId': subscriptionId}) ?? false;

  @override
  Future<bool> checkNow() async => await _ch.invokeMethod<bool>('checkNow') ?? false;

  @override
  Future<bool> scheduleWake(DateTime? at) async =>
      await _ch.invokeMethod<bool>('scheduleWake', {'at': at?.millisecondsSinceEpoch}) ?? false;

  @override
  Future<BackgroundStatus> status() async {
    final m = Map<String, dynamic>.from(await _ch.invokeMethod('status') as Map);
    return BackgroundStatus(
      notifications: m['notifications'] == true, exactAlarms: m['exactAlarms'] == true,
      batteryUnrestricted: m['batteryUnrestricted'] == true, serviceRunning: m['serviceRunning'] == true,
      telephony: m['telephony'] != false, sms: m['sms'] == true, smsPermanentlyDenied: m['smsPermanentlyDenied'] == true,
      contacts: m['contacts'] == true, contactsPermanentlyDenied: m['contactsPermanentlyDenied'] == true,
      notificationsPermanentlyDenied: m['notificationsPermanentlyDenied'] == true,
    );
  }

  @override
  Future<bool> requestNotifications() async => await _ch.invokeMethod<bool>('requestNotifications') ?? false;
  @override
  Future<void> openNotificationSettings() => _ch.invokeMethod('openNotificationSettings');
  @override
  Future<void> openExactAlarmSettings() => _ch.invokeMethod('openExactAlarmSettings');
  @override
  Future<void> openBatterySettings() => _ch.invokeMethod('openBatterySettings');
  @override
  Future<void> openAppSettings() => _ch.invokeMethod('openAppSettings');
}
