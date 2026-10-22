import '../models/email_settings.dart';
import '../models/pro.dart';

/// The email versions of a campaign message: plain text, and simple HTML of the
/// same text. The campaign [signature] and the unsubscribe line (when on) end it.
({String text, String html}) emailBodies(String message, EmailSettings s, {String? signature}) {
  final unsub = s.unsubscribeOn && s.unsubscribeText.trim().isNotEmpty ? s.unsubscribeText.trim() : null;
  final sig = signature?.trim().isEmpty ?? true ? null : signature!.trim();
  final footer = [if (sig != null) sig, if (unsub != null) unsub];
  final text = footer.isEmpty ? message : '$message\n\n--\n${footer.join('\n')}';
  String para(String t) => htmlEscape(t).replaceAll('\n', '<br>');
  // The free signature links to the site.
  String sigHtml(String t) => t == freeSignature
      ? 'Sent via <a href="https://messages.comeriver.com" style="color:#777">messages.comeriver.com</a>'
      : para(t);
  final html = '<div style="font-family:sans-serif;font-size:15px;line-height:1.5">${para(message)}'
      '${footer.isEmpty ? '' : '<p style="color:#777;font-size:12px;margin-top:24px">'
          '${[if (sig != null) sigHtml(sig), if (unsub != null) para(unsub)].join('<br>')}</p>'}</div>';
  return (text: text, html: html);
}

String htmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// `"Ada Okafor" <ada@example.com>`, or just the address without a name.
String formatAddress(String? name, String address) {
  final n = (name ?? '').replaceAll(RegExp(r'["\r\n<>]'), '').trim();
  return n.isEmpty ? address.trim() : '"$n" <${address.trim()}>';
}
