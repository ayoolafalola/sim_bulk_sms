import 'dart:io';
import 'package:flutter/services.dart';
import '../../app/app_info.dart';
import '../../domain/models/statuses.dart';
import 'sms_capability_service.dart';

class AndroidSmsService implements SmsCapabilityService {
  static const _methods = MethodChannel('app.sim_bulk_sms/sms_methods');
  static const _events = EventChannel('app.sim_bulk_sms/sms_events');

  /// The store build never sends directly (no SMS permission in its manifest);
  /// it hands each message to the Messages app instead.
  static const bool directSendingAllowed = !isStoreBuild;

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
    else if (!directSendingAllowed) { blocker = DirectSendBlocker.playPolicyUnresolved;
      msg = 'This version sends through your Messages app, one tap each.'; }
    else if (!granted) { blocker = DirectSendBlocker.permissionDenied; msg = 'SMS permission is off.$fallback'; }
    else if (sims == 0) { blocker = DirectSendBlocker.noSim; msg = 'No active SIM was found.'; }
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
