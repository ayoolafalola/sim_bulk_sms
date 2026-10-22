import 'dart:convert';
import 'dart:io';
import 'email_sender.dart';

/// [HttpPost] with dart:io. A failure to connect means nothing was sent; a
/// timeout after sending leaves the outcome unknown.
Future<HttpReply> ioPost(Uri url, Map<String, String> headers, List<int> body,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final HttpClientRequest req;
    try {
      req = await client.postUrl(url);
    } on Object catch (e) {
      throw RequestNotSentException('Could not reach the email service ($e).');
    }
    headers.forEach(req.headers.set);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    return HttpReply(res.statusCode, text);
  } finally {
    client.close(force: true);
  }
}
