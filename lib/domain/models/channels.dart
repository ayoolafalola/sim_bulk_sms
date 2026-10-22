/// How a campaign reaches people.
enum SendChannel {
  sms, email,
  /// People with both get a text and an email.
  both,
  /// A text when the person has a valid number, otherwise an email.
  smsElseEmail;

  bool get usesEmail => this != SendChannel.sms;
  bool get usesSms => this != SendChannel.email;
}

/// The channel of one recipient row (someone getting both has two rows).
enum MessageChannel { sms, email }

const _sendChannelDb = {
  SendChannel.sms: 'sms', SendChannel.email: 'email', SendChannel.both: 'both',
  SendChannel.smsElseEmail: 'sms_else_email',
};
String sendChannelToDb(SendChannel c) => _sendChannelDb[c]!;
SendChannel sendChannelFromDb(String? s) =>
    _sendChannelDb.entries.firstWhere((e) => e.value == s, orElse: () => const MapEntry(SendChannel.sms, 'sms')).key;

MessageChannel messageChannelFromDb(String? s) => s == 'email' ? MessageChannel.email : MessageChannel.sms;

final _email = RegExp(r'^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$');
bool isValidEmail(String? s) => s != null && _email.hasMatch(s.trim());
