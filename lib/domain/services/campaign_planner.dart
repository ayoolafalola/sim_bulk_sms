import '../../core/sms/sms_segment_estimator.dart';
import '../../core/templates/template_renderer.dart';
import '../models/contact.dart';
import '../models/statuses.dart';
import 'recipient_eligibility.dart';

class SnapshotRecipient {
  const SnapshotRecipient({this.contactId, required this.name, required this.phoneE164, required this.renderedMessage});
  final int? contactId;
  final String name, phoneE164, renderedMessage;
}

class BlockedRecipient {
  const BlockedRecipient(this.contact, this.unresolved);
  final Contact contact;
  final Set<String> unresolved;
}

class CampaignEstimate {
  const CampaignEstimate({required this.messages, required this.totalSegments, required this.maxSegments, required this.unicodeMessages});
  final int messages, totalSegments, maxSegments, unicodeMessages;
}

class SnapshotPlan {
  const SnapshotPlan({required this.recipients, required this.blocked, required this.eligibility,
      required this.estimate, required this.unknownConsentCount});
  final List<SnapshotRecipient> recipients;
  /// Recipients whose message has unresolved variables. They are NOT in
  /// [recipients]; the user must supply fallbacks or fix the data.
  final List<BlockedRecipient> blocked;
  final EligibilityResult eligibility;
  final CampaignEstimate estimate;
  final int unknownConsentCount;
  bool get canSave => blocked.isEmpty && recipients.isNotEmpty;
  Set<String> get unresolvedVariables => {for (final b in blocked) ...b.unresolved};
}

/// Pure: selects eligible recipients (FR-13), renders every message (FR-05),
/// and estimates segments (FR-06). Nothing is persisted here.
SnapshotPlan buildSnapshotPlan({
  required String template,
  required List<Contact> contacts,
  required Set<String> suppressedE164,
  Map<String, String> fallbacks = const {},
}) {
  final elig = filterEligible(contacts, suppressedE164);
  final recs = <SnapshotRecipient>[];
  final blocked = <BlockedRecipient>[];
  final texts = <String>[];
  for (final c in elig.eligible) {
    final r = TemplateRenderer.render(template,
        name: c.name, phone: c.phoneNormalized!, values: {'email': c.email ?? ''}, fallbacks: fallbacks);
    if (r.ok) {
      recs.add(SnapshotRecipient(contactId: c.id, name: c.name, phoneE164: c.phoneNormalized!, renderedMessage: r.text!));
      texts.add(r.text!);
    } else {
      blocked.add(BlockedRecipient(c, r.unresolved));
    }
  }
  return SnapshotPlan(
    recipients: recs, blocked: blocked, eligibility: elig,
    estimate: estimateCampaign(texts),
    unknownConsentCount: elig.eligible.where((c) => c.consent == ConsentStatus.unknown).length,
  );
}

CampaignEstimate estimateCampaign(List<String> rendered) {
  var total = 0, max = 0, uni = 0;
  for (final t in rendered) {
    final e = SmsSegmentEstimator.estimate(t);
    total += e.segments;
    if (e.segments > max) max = e.segments;
    if (e.encoding == SmsEncoding.ucs2) uni++;
  }
  return CampaignEstimate(messages: rendered.length, totalSegments: total, maxSegments: max, unicodeMessages: uni);
}
