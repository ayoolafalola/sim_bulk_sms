import 'statuses.dart';

class Campaign {
  const Campaign({
    required this.id, required this.name, required this.messageTemplate, required this.status,
    required this.platform, this.subscriptionId, required this.recipientCount, required this.createdAt,
  });
  final int id;
  final String name, messageTemplate, platform;
  final CampaignStatus status;
  final int? subscriptionId; // device-specific, not a permanent SIM identity
  final int recipientCount;
  final DateTime createdAt;
}

class CampaignRecipient {
  const CampaignRecipient({
    required this.id, required this.campaignId, this.contactId, required this.name,
    required this.phone, required this.renderedMessage, required this.status, required this.attemptCount,
  });
  final int id, campaignId, attemptCount;
  final int? contactId;
  final String name, phone, renderedMessage;
  final RecipientStatus status;
}

class SnapshotLockedException implements Exception {
  SnapshotLockedException(this.status);
  final String status;
  @override
  String toString() => 'This campaign is $status and its recipients can no longer be changed.';
}
