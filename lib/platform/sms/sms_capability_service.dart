import '../../domain/models/statuses.dart';

enum SmsPlatform { android, ios }
enum DirectSendBlocker {
  none, permissionDenied, permissionPermanentlyDenied, noTelephony, noSim, playPolicyUnresolved,
  /// Android: SMS permissions may only be used while this is the default messaging app (Play policy).
  notDefaultApp,
}

class SmsCapabilities {
  const SmsCapabilities({
    required this.platform,
    required this.canSendDirectly,
    required this.usesComposerHandoff,
    required this.canSelectSim,
    required this.blocker,
    this.messageForUser,
  });
  final SmsPlatform platform;
  final bool canSendDirectly;      // Android only; never true on iOS
  final bool usesComposerHandoff;  // iOS (and Android fallback)
  final bool canSelectSim;
  final DirectSendBlocker blocker;
  final String? messageForUser;
}

class SimSubscription {
  const SimSubscription({required this.id, required this.slotIndex, this.label, this.carrier});
  final int id;          // device-specific; NOT a permanent SIM identity
  final int slotIndex;
  final String? label;
  final String? carrier; // no phone number is inferred
}

class SmsSendRequest {
  const SmsSendRequest({
    required this.campaignRecipientId, required this.attemptId,
    required this.phoneE164, required this.body, this.subscriptionId,
  });
  final int campaignRecipientId;
  final int attemptId;
  final String phoneE164;
  final String body;
  final int? subscriptionId;
}

/// Event from the native layer. Always carries both ids (spec §8.1).
class SmsEvent {
  const SmsEvent({required this.type, required this.campaignRecipientId, required this.attemptId, this.errorCode, this.errorMessage});
  final String type; // sendStarted | sendSucceeded | sendFailed | deliveryReported | composerResult
  final int campaignRecipientId;
  final int attemptId;
  final String? errorCode;
  final String? errorMessage;
}

/// Android: `submitted` now, final result arrives via [events].
/// iOS: `awaitingUserAction` now; composer result arrives via [events].
class SmsOperationResult {
  const SmsOperationResult(this.status, {this.errorCode, this.errorMessage, this.storedMessageId});
  final RecipientStatus status;
  final String? errorCode;
  final String? errorMessage;
  /// Android default messaging app: the text's row in the phone's message store.
  final int? storedMessageId;
}

abstract class SmsCapabilityService {
  Future<SmsCapabilities> getCapabilities();
  Future<bool> requestRequiredPermissions();
  /// Empty on iOS. Never fabricates SIM details.
  Future<List<SimSubscription>> getAvailableSubscriptions();
  Future<SmsOperationResult> sendMessage(SmsSendRequest request);
  Stream<SmsEvent> get events;
}
