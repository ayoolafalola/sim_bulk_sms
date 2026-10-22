import 'dart:convert';
import '../../domain/models/email_settings.dart';
import '../../domain/services/email_body.dart';
import 'email_sender.dart';
import 'io_http.dart';

/// Mailgun's API, or any service built like it: `POST {base}/{domain}/messages`
/// with Basic auth `api:KEY` and form fields from, to, subject, text, html.
class MailgunSender implements EmailSender {
  MailgunSender(this.settings, {HttpPost? post}) : _post = post ?? ioPost;
  final EmailSettings settings;
  final HttpPost _post;

  Uri get url =>
      Uri.parse('${settings.baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/${settings.domain.trim()}/messages');

  @override
  Future<void> prepare() async {
    if (settings.provider != EmailProvider.mailgun || !settings.ready) {
      throw EmailNotReadyException('Set up email in Settings › Email first.');
    }
  }

  Map<String, String> fields(OutgoingEmail e) => {
        'from': formatAddress(settings.fromName, settings.fromAddress),
        'to': formatAddress(e.toName, e.toAddress),
        'subject': e.subject,
        'text': e.text,
        'html': e.html,
        'v:campaign_id': '${e.campaignId}',
        'v:message_id': e.id,
        if (settings.unsubscribeOn) 'h:List-Unsubscribe': '<mailto:${settings.fromAddress.trim()}?subject=unsubscribe>',
      };

  @override
  Future<EmailResult> send(OutgoingEmail e) async {
    final HttpReply reply;
    try {
      reply = await _post(url, {
        'Authorization': 'Basic ${base64.encode(utf8.encode('api:${settings.apiKey.trim()}'))}',
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
      }, utf8.encode(Uri(queryParameters: fields(e)).query));
    } on RequestNotSentException catch (x) {
      return EmailResult(EmailOutcome.failed, errorCode: 'network', errorMessage: x.message);
    } catch (x) {
      return EmailResult(EmailOutcome.unknown, errorCode: 'timeout', errorMessage: 'No answer from the email service ($x).');
    }
    String? id, message;
    try {
      final j = jsonDecode(reply.body);
      if (j is Map) {
        id = j['id'] as String?;
        message = j['message'] as String?;
      }
    } catch (_) {/* not JSON: keep the default message */}
    return resultForStatus(reply.status,
        providerId: id, message: reply.status >= 400 && reply.status < 500 ? message : null);
  }
}
