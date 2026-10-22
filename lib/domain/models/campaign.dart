import 'channels.dart';
import 'statuses.dart';

class Campaign {
  const Campaign({
    required this.id, required this.name, required this.messageTemplate, required this.status,
    required this.platform, this.subscriptionId, required this.recipientCount, required this.createdAt,
    this.sourceCampaignId, this.scheduleId, this.pausedReason, this.resumeAt,
    this.channel = SendChannel.sms, this.subject,
  });
  final int id;
  final String name, messageTemplate, platform;
  final CampaignStatus status;
  final int? subscriptionId; // device-specific, not a permanent SIM identity
  final int recipientCount;
  final DateTime createdAt;
  /// Set on a resend or scheduled run: the campaign it was created from.
  final int? sourceCampaignId;
  /// Set on a scheduled run: the schedule that created it.
  final int? scheduleId;
  /// Why it is paused: 'user', 'hourly_limit' or 'daily_limit' (null otherwise).
  final String? pausedReason;
  /// When a limit-paused campaign resumes by itself (local time).
  final DateTime? resumeAt;
  final SendChannel channel;
  /// Email subject template (email channels only).
  final String? subject;
}

/// Who a campaign targets: whole groups and/or individual contacts.
class CampaignAudience {
  const CampaignAudience({this.groupIds = const {}, this.contactIds = const {}});
  final Set<int> groupIds, contactIds;
  bool get isEmpty => groupIds.isEmpty && contactIds.isEmpty;
}

class CampaignRecipient {
  const CampaignRecipient({
    required this.id, required this.campaignId, this.contactId, required this.name,
    required this.phone, required this.renderedMessage, required this.status, required this.attemptCount,
    this.channel = MessageChannel.sms, this.email, this.subject,
  });
  final int id, campaignId, attemptCount;
  final int? contactId;
  /// E.164 number; may be empty on an email row.
  final String name, phone, renderedMessage;
  final RecipientStatus status;
  final MessageChannel channel;
  /// Email rows: address and rendered subject.
  final String? email, subject;
  bool get isEmail => channel == MessageChannel.email;
  /// Where it goes: the number or the email address.
  String get address => isEmail ? (email ?? '') : phone;
}

class SnapshotLockedException implements Exception {
  SnapshotLockedException(this.status);
  final String status;
  @override
  String toString() => 'This campaign is $status and its recipients can no longer be changed.';
}
