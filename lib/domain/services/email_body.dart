import '../models/email_settings.dart';

/// The email versions of a campaign message: plain text, and simple HTML of the
/// same text. The unsubscribe line is added at the end when it's on.
({String text, String html}) emailBodies(String message, EmailSettings s) {
  final footer = s.unsubscribeOn && s.unsubscribeText.trim().isNotEmpty ? s.unsubscribeText.trim() : null;
  final text = footer == null ? message : '$message\n\n--\n$footer';
  String para(String t) => htmlEscape(t).replaceAll('\n', '<br>');
  final html = '<div style="font-family:sans-serif;font-size:15px;line-height:1.5">${para(message)}'
      '${footer == null ? '' : '<p style="color:#777;font-size:12px;margin-top:24px">${para(footer)}</p>'}</div>';
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
