import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../domain/models/statuses.dart';
import 'sms_capability_service.dart';

class AndroidSmsService implements SmsCapabilityService {
  static const _methods = MethodChannel('app.sim_bulk_sms/sms_methods');
  static const _events = EventChannel('app.sim_bulk_sms/sms_events');

  /// Release gate: keep false until Google Play approval/exception is documented
  /// in docs/PERMISSIONS_AND_STORE_POLICY.md. Debug builds (`flutter run`) are
  /// never distributed, so they may send; release builds need the define.
  static const bool playPolicyResolved =
      kDebugMode || bool.fromEnvironment('PLAY_SMS_POLICY_RESOLVED', defaultValue: false);

  @override
  Future<SmsCapabilities> getCapabilities() async {
    assert(Platform.isAndroid);
    final m = Map<String, dynamic>.from(await _methods.invokeMethod('getCapabilities'));
    final hasTelephony = m['hasTelephony'] == true;
    final granted = m['sendSmsGranted'] == true;
    final sims = (m['activeSubscriptions'] as int?) ?? 0;
    var blocker = DirectSendBlocker.none;
    String? msg;
    const fallback = ' Messages open in your Messages app instead, one tap each.';
    if (!hasTelephony) { blocker = DirectSendBlocker.noTelephony; msg = 'This device has no telephony hardware.'; }
    else if (!granted) { blocker = DirectSendBlocker.permissionDenied; msg = 'SMS permission is off.$fallback'; }
    else if (sims == 0) { blocker = DirectSendBlocker.noSim; msg = 'No active SIM was found.'; }
    else if (!playPolicyResolved) { blocker = DirectSendBlocker.playPolicyUnresolved;
      msg = 'Automatic sending is off in this version.$fallback'; }
    return SmsCapabilities(
      platform: SmsPlatform.android,
      canSendDirectly: blocker == DirectSendBlocker.none,
      // Messages-app fallback whenever the phone can text but direct sending isn't allowed.
      usesComposerHandoff: hasTelephony && blocker != DirectSendBlocker.none && blocker != DirectSendBlocker.noSim,
      canSelectSim: sims > 1,
      blocker: blocker,
      messageForUser: msg,
    );
  }

  @override
  Future<bool> requestRequiredPermissions() async =>
      (await _methods.invokeMethod<bool>('requestPermissions')) ?? false;

  @override
  Future<List<SimSubscription>> getAvailableSubscriptions() async {
    final list = await _methods.invokeMethod<List<dynamic>>('getSubscriptions') ?? [];
    return list.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return SimSubscription(id: m['id'] as int, slotIndex: m['slot'] as int,
          label: m['label'] as String?, carrier: m['carrier'] as String?);
    }).toList();
  }

  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async {
    final caps = await getCapabilities();
    if (!caps.canSendDirectly) {
      return SmsOperationResult(RecipientStatus.failed,
          errorCode: caps.blocker.name, errorMessage: caps.messageForUser);
    }
    try {
      await _methods.invokeMethod('sendTextMessage', {
        'recipientId': r.campaignRecipientId, 'attemptId': r.attemptId,
        'phone': r.phoneE164, 'body': r.body, 'subscriptionId': r.subscriptionId,
      });
      return const SmsOperationResult(RecipientStatus.submitted); // NOT sent yet
    } on PlatformException catch (e) {
      return SmsOperationResult(RecipientStatus.failed, errorCode: e.code, errorMessage: e.message);
    }
  }

  @override
  Stream<SmsEvent> get events => _events.receiveBroadcastStream().map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return SmsEvent(type: m['type'] as String, campaignRecipientId: m['recipientId'] as int,
            attemptId: m['attemptId'] as int, errorCode: m['errorCode']?.toString(),
            errorMessage: m['errorMessage'] as String?);
      });
}
