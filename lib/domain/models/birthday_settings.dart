import 'dart:convert';
import 'channels.dart';

/// Birthday wishes (Comeriver Pro): every day at [minuteOfDay], everyone whose birthday it is gets [template].
class BirthdaySettings {
  const BirthdaySettings({
    this.enabled = false,
    this.channel = SendChannel.sms,
    this.template = defaultTemplate,
    this.subject = defaultSubject,
    this.minuteOfDay = 8 * 60,
    this.groupIds = const {},
    this.lastRunDate,
  });
  static const defaultTemplate = 'Happy birthday {first_name}! Wishing you a wonderful year ahead.';
  static const defaultSubject = 'Happy birthday, {first_name}!';

  final bool enabled;
  final SendChannel channel;
  final String template, subject;
  /// Local time of day to send, minutes after midnight.
  final int minuteOfDay;
  /// Only these groups; empty = everyone with a birthday.
  final Set<int> groupIds;
  /// The last day (YYYY-MM-DD, local) the wishes ran.
  final String? lastRunDate;

  BirthdaySettings copyWith({
    bool? enabled, SendChannel? channel, String? template, String? subject, int? minuteOfDay, Set<int>? groupIds,
    String? lastRunDate,
  }) =>
      BirthdaySettings(
        enabled: enabled ?? this.enabled, channel: channel ?? this.channel, template: template ?? this.template,
        subject: subject ?? this.subject, minuteOfDay: minuteOfDay ?? this.minuteOfDay,
        groupIds: groupIds ?? this.groupIds, lastRunDate: lastRunDate ?? this.lastRunDate,
      );

  String toJson() => jsonEncode({
        'enabled': enabled, 'channel': sendChannelToDb(channel), 'template': template, 'subject': subject,
        'minuteOfDay': minuteOfDay, 'groupIds': groupIds.toList(), 'lastRunDate': lastRunDate,
      });

  static BirthdaySettings fromJson(String? s) {
    if (s == null) return const BirthdaySettings();
    final m = jsonDecode(s) as Map<String, dynamic>;
    return BirthdaySettings(
      enabled: m['enabled'] as bool? ?? false,
      channel: sendChannelFromDb(m['channel'] as String?),
      template: m['template'] as String? ?? defaultTemplate,
      subject: m['subject'] as String? ?? defaultSubject,
      minuteOfDay: (m['minuteOfDay'] as int? ?? 8 * 60).clamp(0, 24 * 60 - 1),
      groupIds: {for (final g in (m['groupIds'] as List? ?? const [])) g as int},
      lastRunDate: m['lastRunDate'] as String?,
    );
  }
}

/// "2026-10-26" for a local date.
String dayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
