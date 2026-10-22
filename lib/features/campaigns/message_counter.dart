import 'package:flutter/material.dart';
import '../../core/sms/sms_segment_estimator.dart';
import '../../domain/services/campaign_planner.dart';

/// The message to count: the longest real message once recipients are known
/// (placeholders filled in), otherwise the template text itself.
({String text, String? forName}) messageToCount(String template, SnapshotPlan? plan) {
  if (plan == null || plan.recipients.isEmpty) return (text: template, forName: null);
  SnapshotRecipient longest = plan.recipients.first;
  var best = SmsSegmentEstimator.estimate(longest.renderedMessage);
  for (final r in plan.recipients.skip(1)) {
    final e = SmsSegmentEstimator.estimate(r.renderedMessage);
    if (e.segments > best.segments || (e.segments == best.segments && e.units > best.units)) {
      longest = r;
      best = e;
    }
  }
  return (text: longest.renderedMessage, forName: plan.recipients.length > 1 ? longest.name : null);
}

/// Live "112 characters · 1 SMS" under the message box, with a warning and a
/// one-tap fix when special characters force the shorter Unicode SMS.
class MessageCounter extends StatelessWidget {
  const MessageCounter({super.key, required this.template, this.plan, this.onUsePlain});
  final String template;
  final SnapshotPlan? plan;
  /// Called with the template rewritten using plain look-alike characters.
  final ValueChanged<String>? onUsePlain;

  @override
  Widget build(BuildContext context) {
    if (template.isEmpty) return const SizedBox.shrink();
    final m = messageToCount(template, plan);
    final e = SmsSegmentEstimator.estimate(m.text);
    final left = e.perSegmentLimit * e.segments - e.units;
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final special = e.encoding == SmsEncoding.ucs2 ? SmsSegmentEstimator.nonGsmCharacters(m.text) : const <String>[];
    final plain = SmsSegmentEstimator.toPlainCharacters(template);
    final fixable = special.isNotEmpty && plain != template;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          [
            if (m.forName != null) 'Longest message (${m.forName}):',
            '${e.units} characters · ${e.segments} SMS',
            if (e.segments > 0) '$left left in this SMS',
          ].join(' · ').replaceFirst(': ·', ':'),
          style: small,
        ),
        if (special.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Special characters (${special.map((c) => c == ' ' ? 'non-breaking space' : c).join(' ')}) '
            'limit each SMS to 70 characters instead of 160.',
            style: small?.copyWith(color: scheme.tertiary),
          ),
          if (fixable && onUsePlain != null)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
              onPressed: () => onUsePlain!(plain),
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('Use plain characters'),
            ),
        ],
      ]),
    );
  }
}
