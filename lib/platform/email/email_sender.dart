/// One campaign email, ready to send.
class OutgoingEmail {
  const OutgoingEmail({
    required this.id, required this.campaignId, required this.toAddress, this.toName,
    required this.subject, required this.text, required this.html,
  });
  /// Unique per attempt ("cr-<recipient>-<attempt>"), sent along so the
  /// provider (and webhooks) can tell duplicates apart.
  final String id;
  final int campaignId;
  final String toAddress;
  final String? toName;
  final String subject, text, html;
}

enum EmailOutcome {
  /// Accepted by the provider.
  sent,
  /// Certainly not sent (refused, or never reached the provider).
  failed,
  /// May or may not have been sent (timeout, server error): never retried automatically.
  unknown,
}

class EmailResult {
  const EmailResult(this.outcome, {this.providerId, this.errorCode, this.errorMessage});
  final EmailOutcome outcome;
  final String? providerId, errorCode, errorMessage;
}

/// Sending can't start (not set up, Gmail needs signing in again…). Nothing was sent.
class EmailNotReadyException implements Exception {
  EmailNotReadyException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class EmailSender {
  /// Checks sending can start (e.g. gets a Gmail token). Throws [EmailNotReadyException].
  Future<void> prepare();
  Future<EmailResult> send(OutgoingEmail email);
}

class HttpReply {
  const HttpReply(this.status, this.body);
  final int status;
  final String body;
}

/// The request never left the phone (no connection, bad host): certainly not sent.
class RequestNotSentException implements Exception {
  RequestNotSentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// POSTs [body]; throws [RequestNotSentException] if it couldn't be sent at all,
/// anything else (timeout…) if the outcome is uncertain.
typedef HttpPost = Future<HttpReply> Function(Uri url, Map<String, String> headers, List<int> body);

/// Maps an HTTP status to an outcome: 2xx sent, 5xx unknown, other failed.
EmailResult resultForStatus(int status, {String? providerId, String? message}) {
  if (status >= 200 && status < 300) return EmailResult(EmailOutcome.sent, providerId: providerId);
  if (status >= 500) {
    return EmailResult(EmailOutcome.unknown, errorCode: 'http_$status', errorMessage: message ?? 'The email service had an error.');
  }
  final (code, text) = switch (status) {
    401 || 403 => ('auth', 'The email service refused the login. Check the API key or account.'),
    404 => ('not_found', 'The email service address was not found. Check the base URL and sending domain.'),
    429 => ('rate_limited', 'The email service is limiting how fast you send. Try again later.'),
    _ => ('rejected', 'The email service refused this email.'),
  };
  return EmailResult(EmailOutcome.failed, errorCode: code, errorMessage: message ?? text);
}
