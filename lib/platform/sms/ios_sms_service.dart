import 'dart:async';
import 'package:flutter/services.dart';
import '../../domain/models/statuses.dart';
import 'sms_capability_service.dart';

/// iOS: composer handoff only. The user must tap Send for every composer.
class IosSmsService implements SmsCapabilityService {
  static const _methods = MethodChannel('app.sim_bulk_sms/sms_methods');
  final _controller = StreamController<SmsEvent>.broadcast();

  @override
  Future<SmsCapabilities> getCapabilities() async {
    final m = Map<String, dynamic>.from(await _methods.invokeMethod('getCapabilities'));
    final can = m['canSendText'] == true;
    return SmsCapabilities(
      platform: SmsPlatform.ios, canSendDirectly: false, usesComposerHandoff: can, canSelectSim: false,
      blocker: DirectSendBlocker.none,
      messageForUser: can
          ? 'Texts open in Messages, where you review them and tap Send.'
          : 'This device cannot send SMS (no cellular/Messages configured).');
  }

  @override
  Future<bool> requestRequiredPermissions() async => true; // none required

  @override
  Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];

  /// Awaits the composer. Result mapping: sent->sent (queued by iOS, not delivered),
  /// cancelled->cancelled, failed->failed, unavailable/unsupported->failed with code.
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async {
    try {
      final res = await _methods.invokeMethod<String>('presentMessageComposer',
          {'recipients': [r.phoneE164], 'body': r.body});
      switch (res) {
        case 'sent': return const SmsOperationResult(RecipientStatus.sent);
        case 'cancelled': return const SmsOperationResult(RecipientStatus.cancelled);
        case 'failed': return const SmsOperationResult(RecipientStatus.failed, errorCode: 'composer_failed');
        case 'unavailable': return const SmsOperationResult(RecipientStatus.failed, errorCode: 'composer_unavailable');
        default: return const SmsOperationResult(RecipientStatus.unknown, errorCode: 'composer_unsupported');
      }
    } on PlatformException catch (e) {
      return SmsOperationResult(RecipientStatus.unknown, errorCode: e.code, errorMessage: e.message);
    }
  }

  /// One composer with several recipients ("send to all at once"). Returns the composer's outcome:
  /// 'sent' (the user tapped Send), 'cancelled', 'failed', 'unavailable' or 'unsupported'.
  Future<String> composeMany(List<String> phones, String body) async {
    try {
      return await _methods.invokeMethod<String>('presentMessageComposer', {'recipients': phones, 'body': body}) ??
          'unsupported';
    } on PlatformException {
      return 'failed';
    }
  }

  @override
  Stream<SmsEvent> get events => _controller.stream;
}
