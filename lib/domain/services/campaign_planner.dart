import '../../core/sms/sms_segment_estimator.dart';
import '../../core/templates/template_renderer.dart';
import '../models/channels.dart';
import '../models/contact.dart';
import '../models/statuses.dart';
import 'recipient_eligibility.dart';

class SnapshotRecipient {
  const SnapshotRecipient({this.contactId, required this.name, required this.phoneE164, required this.renderedMessage,
      this.channel = MessageChannel.sms, this.email, this.subject});
  final int? contactId;
  /// E.164; empty for an email row of someone without a valid number.
  final String name, phoneE164, renderedMessage;
  final MessageChannel channel;
  final String? email, subject;
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
  int get smsCount => recipients.where((r) => r.channel == MessageChannel.sms).length;
  int get emailCount => recipients.where((r) => r.channel == MessageChannel.email).length;
  bool get canSave => blocked.isEmpty && recipients.isNotEmpty;
  Set<String> get unresolvedVariables => {for (final b in blocked) ...b.unresolved};
}

/// Pure: selects eligible recipients (FR-13), renders every message (FR-05),
/// and estimates segments (FR-06). Nothing is persisted here.
///
/// [channel] decides the rows: a text (needs a valid number), an email (needs a
/// valid address and renders [subjectTemplate] too), or both. Suppression and
/// opting out apply to every channel. Each number and each address is used once.
SnapshotPlan buildSnapshotPlan({
  required String template,
  required List<Contact> contacts,
  required Set<String> suppressedE164,
  Map<String, String> fallbacks = const {},
  SendChannel channel = SendChannel.sms,
  String subjectTemplate = '',
}) {
  final ok = <Contact>[], sup = <Contact>[], opt = <Contact>[], inv = <Contact>[];
  final seenPhones = <String>{}, seenEmails = <String>{};
  final recs = <SnapshotRecipient>[];
  final blocked = <BlockedRecipient>[];
  final texts = <String>[];
  for (final c in contacts) {
    final phone = c.phoneNormalized;
    final email = isValidEmail(c.email) ? c.email!.trim() : null;
    if (phone != null && suppressedE164.contains(phone)) { sup.add(c); continue; }
    if (c.consent == ConsentStatus.optedOut) { opt.add(c); continue; }
    var sms = channel.usesSms && phone != null;
    var mail = switch (channel) {
      SendChannel.sms => false,
      SendChannel.email || SendChannel.both => email != null,
      SendChannel.smsElseEmail => phone == null && email != null,
    };
    if (!sms && !mail) { inv.add(c); continue; }
    if (sms && !seenPhones.add(phone)) sms = false; // same number twice in one selection: send once
    if (mail && !seenEmails.add(email!.toLowerCase())) mail = false;
    if (!sms && !mail) continue;
    ok.add(c);

    final values = {
      'email': c.email ?? '', 'company': c.organization ?? '',
      'birthday': c.birthday == null ? '' : formatContactDate(c.birthday!),
    };
    final r = TemplateRenderer.render(template, name: c.name, phone: phone ?? '', values: values, fallbacks: fallbacks);
    final subj = mail
        ? TemplateRenderer.render(subjectTemplate, name: c.name, phone: phone ?? '', values: values, fallbacks: fallbacks)
        : null;
    if (!r.ok || (subj != null && !subj.ok)) {
      blocked.add(BlockedRecipient(c, {...r.unresolved, ...?subj?.unresolved}));
      continue;
    }
    if (sms) {
      recs.add(SnapshotRecipient(contactId: c.id, name: c.name, phoneE164: phone!, renderedMessage: r.text!));
      texts.add(r.text!);
    }
    if (mail) {
      recs.add(SnapshotRecipient(contactId: c.id, name: c.name, phoneE164: phone ?? '', renderedMessage: r.text!,
          channel: MessageChannel.email, email: email, subject: subj!.text));
    }
  }
  return SnapshotPlan(
    recipients: recs, blocked: blocked, eligibility: EligibilityResult(ok, sup, opt, inv),
    estimate: estimateCampaign(texts),
    unknownConsentCount: ok.where((c) => c.consent == ConsentStatus.unknown).length,
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
