import 'package:flutter/material.dart';
import '../../core/sms/sms_segment_estimator.dart';
import '../../domain/models/channels.dart';
import '../../domain/models/pro.dart';
import '../../domain/services/campaign_planner.dart';

/// The message to count: the longest real message once recipients are known
/// (placeholders filled in), otherwise the template text itself.
/// With a [signature], it is counted too (it's added to every campaign text).
({String text, String? forName}) messageToCount(String template, SnapshotPlan? plan, {String? signature}) {
  final texts = plan?.recipients.where((r) => r.channel == MessageChannel.sms).toList() ?? const [];
  if (texts.isEmpty) return (text: withSignature(template, signature), forName: null);
  SnapshotRecipient longest = texts.first;
  var best = SmsSegmentEstimator.estimate(withSignature(longest.renderedMessage, signature));
  for (final r in texts.skip(1)) {
    final e = SmsSegmentEstimator.estimate(withSignature(r.renderedMessage, signature));
    if (e.segments > best.segments || (e.segments == best.segments && e.units > best.units)) {
      longest = r;
      best = e;
    }
  }
  return (text: withSignature(longest.renderedMessage, signature), forName: texts.length > 1 ? longest.name : null);
}

/// Live "112 characters · 1 SMS" under the message box, with a warning and a
/// one-tap fix when special characters force the shorter Unicode SMS.
class MessageCounter extends StatelessWidget {
  const MessageCounter({super.key, required this.template, this.plan, this.onUsePlain, this.signature});
  final String template;
  final SnapshotPlan? plan;
  /// The campaign signature, counted in (null = none).
  final String? signature;
  /// Called with the template rewritten using plain look-alike characters.
  final ValueChanged<String>? onUsePlain;

  @override
  Widget build(BuildContext context) {
    if (template.isEmpty) return const SizedBox.shrink();
    final m = messageToCount(template, plan, signature: signature);
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
            if (signature != null) 'signature included',
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
