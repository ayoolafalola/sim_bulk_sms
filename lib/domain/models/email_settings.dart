import 'dart:convert';

enum EmailProvider { off, mailgun, gmail }

/// How campaign emails are sent (Settings › Email). Stored in the database so
/// the background service uses the same values.
class EmailSettings {
  const EmailSettings({
    this.provider = EmailProvider.off,
    this.baseUrl = mailgunUs,
    this.domain = '',
    this.apiKey = '',
    this.fromName = '',
    this.fromAddress = '',
    this.hourlyLimit = defaultHourlyLimit,
    this.dailyLimit = defaultDailyLimit,
    this.unsubscribeOn = true,
    this.unsubscribeText = defaultUnsubscribeText,
    this.gmailAccount,
  });
  static const mailgunUs = 'https://api.mailgun.net/v3', mailgunEu = 'https://api.eu.mailgun.net/v3';
  static const defaultHourlyLimit = 50, defaultDailyLimit = 400;
  static const defaultUnsubscribeText = "Don't want these emails? Reply STOP and we'll take you off the list.";

  final EmailProvider provider;
  /// Mailgun-compatible API: emails are POSTed to `{baseUrl}/{domain}/messages`.
  final String baseUrl, domain, apiKey;
  final String fromName, fromAddress;
  /// Emails in any rolling 60 minutes / 24 hours; 0 = off.
  final int hourlyLimit, dailyLimit;
  final bool unsubscribeOn;
  final String unsubscribeText;
  /// The connected Gmail address (Gmail provider).
  final String? gmailAccount;

  /// Everything needed to send is filled in.
  bool get ready => switch (provider) {
        EmailProvider.off => false,
        EmailProvider.mailgun =>
          baseUrl.trim().startsWith('https://') && domain.trim().isNotEmpty && apiKey.trim().isNotEmpty &&
              fromAddress.trim().isNotEmpty,
        EmailProvider.gmail => gmailAccount != null,
      };

  /// The address emails come from (and replies go to).
  String get senderAddress => provider == EmailProvider.gmail ? (gmailAccount ?? '') : fromAddress.trim();

  String get providerLabel => switch (provider) {
        EmailProvider.off => 'Off',
        EmailProvider.mailgun => 'Mailgun API',
        EmailProvider.gmail => 'Gmail',
      };

  EmailSettings copyWith({
    EmailProvider? provider, String? baseUrl, String? domain, String? apiKey, String? fromName, String? fromAddress,
    int? hourlyLimit, int? dailyLimit, bool? unsubscribeOn, String? unsubscribeText,
    String? gmailAccount, bool clearGmail = false,
  }) =>
      EmailSettings(
        provider: provider ?? this.provider, baseUrl: baseUrl ?? this.baseUrl, domain: domain ?? this.domain,
        apiKey: apiKey ?? this.apiKey, fromName: fromName ?? this.fromName, fromAddress: fromAddress ?? this.fromAddress,
        hourlyLimit: hourlyLimit ?? this.hourlyLimit, dailyLimit: dailyLimit ?? this.dailyLimit,
        unsubscribeOn: unsubscribeOn ?? this.unsubscribeOn, unsubscribeText: unsubscribeText ?? this.unsubscribeText,
        gmailAccount: clearGmail ? null : gmailAccount ?? this.gmailAccount,
      );

  String toJson() => jsonEncode({
        'provider': provider.name, 'baseUrl': baseUrl, 'domain': domain, 'apiKey': apiKey,
        'fromName': fromName, 'fromAddress': fromAddress, 'hourlyLimit': hourlyLimit, 'dailyLimit': dailyLimit,
        'unsubscribeOn': unsubscribeOn, 'unsubscribeText': unsubscribeText, 'gmailAccount': gmailAccount,
      });

  static EmailSettings fromJson(String? s) {
    if (s == null) return const EmailSettings();
    final m = jsonDecode(s) as Map<String, dynamic>;
    return EmailSettings(
      provider: EmailProvider.values.firstWhere((p) => p.name == m['provider'], orElse: () => EmailProvider.off),
      baseUrl: m['baseUrl'] as String? ?? mailgunUs,
      domain: m['domain'] as String? ?? '',
      apiKey: m['apiKey'] as String? ?? '',
      fromName: m['fromName'] as String? ?? '',
      fromAddress: m['fromAddress'] as String? ?? '',
      hourlyLimit: (m['hourlyLimit'] as int? ?? defaultHourlyLimit).clamp(0, 100000),
      dailyLimit: (m['dailyLimit'] as int? ?? defaultDailyLimit).clamp(0, 100000),
      unsubscribeOn: m['unsubscribeOn'] as bool? ?? true,
      unsubscribeText: m['unsubscribeText'] as String? ?? defaultUnsubscribeText,
      gmailAccount: m['gmailAccount'] as String?,
    );
  }
}
