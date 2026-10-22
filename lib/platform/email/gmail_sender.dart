import 'dart:convert';
import 'dart:math';
import '../../domain/models/email_settings.dart';
import 'email_sender.dart';
import 'io_http.dart';

/// Access to the connected Gmail account (send-only permission).
abstract class GmailAuth {
  /// A current access token without asking the user, or null if they must sign in again.
  Future<String?> token();
  /// Forget a token Google refused, so the next [token] call gets a fresh one.
  Future<void> clear(String token);
}

/// Sends through the Gmail API as the connected account.
class GmailSender implements EmailSender {
  GmailSender(this.settings, this.auth, {HttpPost? post}) : _post = post ?? ioPost;
  final EmailSettings settings;
  final GmailAuth auth;
  final HttpPost _post;
  String? _token;

  static final url = Uri.parse('https://gmail.googleapis.com/gmail/v1/users/me/messages/send');

  @override
  Future<void> prepare() async {
    if (settings.provider != EmailProvider.gmail || settings.gmailAccount == null) {
      throw EmailNotReadyException('Connect Gmail in Settings › Email first.');
    }
    _token = await auth.token();
    if (_token == null) {
      throw EmailNotReadyException('Gmail needs you to sign in again: open Settings › Email and connect Gmail.');
    }
  }

  @override
  Future<EmailResult> send(OutgoingEmail e) async {
    if (_token == null) await prepare();
    final body = utf8.encode(jsonEncode({'raw': base64Url.encode(utf8.encode(buildMime(e))).replaceAll('=', '')}));
    for (var attempt = 0; attempt < 2; attempt++) {
      final HttpReply reply;
      try {
        reply = await _post(url, {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'}, body);
      } on RequestNotSentException catch (x) {
        return EmailResult(EmailOutcome.failed, errorCode: 'network', errorMessage: x.message);
      } catch (x) {
        return EmailResult(EmailOutcome.unknown, errorCode: 'timeout', errorMessage: 'No answer from Gmail ($x).');
      }
      if (reply.status == 401 && attempt == 0) {
        // Expired token: Gmail refused the request, so nothing was sent. Get a fresh one once.
        await auth.clear(_token!);
        _token = await auth.token();
        if (_token == null) break;
        continue;
      }
      String? id, message;
      try {
        final j = jsonDecode(reply.body);
        if (j is Map) {
          id = j['id'] as String?;
          message = (j['error'] as Map?)?['message'] as String?;
        }
      } catch (_) {}
      if (reply.status == 403 || reply.status == 429) {
        return EmailResult(EmailOutcome.failed, errorCode: 'quota',
            errorMessage: message ?? 'Gmail refused: sending limit reached. Try again tomorrow.');
      }
      return resultForStatus(reply.status, providerId: id, message: reply.status >= 400 && reply.status < 500 ? message : null);
    }
    return const EmailResult(EmailOutcome.failed, errorCode: 'gmail_auth',
        errorMessage: 'Gmail needs you to sign in again: open Settings › Email and connect Gmail.');
  }

  /// The message in Internet mail format (what Gmail's API takes).
  String buildMime(OutgoingEmail e) {
    final boundary = 'cm_${Random().nextInt(1 << 32).toRadixString(16)}${e.id.hashCode.toRadixString(16)}';
    String enc(String s) => s.codeUnits.every((c) => c < 128) ? s : '=?UTF-8?B?${base64.encode(utf8.encode(s))}?=';
    String addr(String? name, String address) {
      final n = (name ?? '').replaceAll(RegExp(r'["\r\n<>]'), '').trim();
      return n.isEmpty ? address : '${enc(n)} <$address>';
    }
    String b64(String s) {
      final all = base64.encode(utf8.encode(s));
      return [for (var i = 0; i < all.length; i += 76) all.substring(i, min(i + 76, all.length))].join('\r\n');
    }
    final from = settings.gmailAccount ?? '';
    return [
      'From: ${addr(settings.fromName, from)}',
      'To: ${addr(e.toName, e.toAddress)}',
      'Subject: ${enc(e.subject.replaceAll(RegExp(r'[\r\n]+'), ' '))}',
      'MIME-Version: 1.0',
      if (settings.unsubscribeOn) 'List-Unsubscribe: <mailto:$from?subject=unsubscribe>',
      'X-Campaign-Message-Id: ${e.id}',
      'Content-Type: multipart/alternative; boundary="$boundary"',
      '',
      '--$boundary',
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      '',
      b64(e.text),
      '--$boundary',
      'Content-Type: text/html; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      '',
      b64(e.html),
      '--$boundary--',
      '',
    ].join('\r\n');
  }
}
