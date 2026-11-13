import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'contacts_plus_config.dart';

/// A safe, user-facing failure from the Contacts++ service.
class ContactsPlusException implements Exception {
  const ContactsPlusException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;

  /// The server's error code when it sent one (e.g. `insufficient_scope`).
  final String? code;

  /// Nothing reached the server, or it never answered: safe to retry later.
  bool get offline => statusCode == null;

  @override
  String toString() => message;
}

/// JSON client for the Contacts++ `/api/v1` service.
///
/// A 401 is retried once with a refreshed token ([tokenRefresher]); a second
/// 401 calls [onSessionRejected] so the app can sign out locally.
class ContactsPlusApi {
  ContactsPlusApi({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? ContactsPlusConfig.apiBaseUrl;

  final http.Client _client;
  final String _baseUrl;
  static const _timeout = Duration(seconds: 20);

  Future<String?> Function(String failedToken)? tokenRefresher;
  Future<void> Function()? onSessionRejected;

  Future<Map<String, dynamic>> get(String path, {String? token}) => _send('GET', path, token: token);

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body, {String? token}) => _send('POST', path, token: token, body: body);

  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body, {String? token}) => _send('PUT', path, token: token, body: body);

  Future<Map<String, dynamic>> delete(String path, {String? token, Map<String, dynamic>? body}) => _send('DELETE', path, token: token, body: body);

  Future<Map<String, dynamic>> _send(String method, String path, {String? token, Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$_baseUrl$path');
    Future<http.Response> attempt(String? bearer) async {
      final request = http.Request(method, uri)
        ..headers.addAll({
          'Accept': 'application/json',
          if (body != null) 'Content-Type': 'application/json',
          if (bearer != null) 'Authorization': 'Bearer $bearer',
        });
      if (body != null) request.body = jsonEncode(body);
      try {
        return await http.Response.fromStream(await _client.send(request).timeout(_timeout)).timeout(_timeout);
      } on TimeoutException {
        throw const ContactsPlusException('Contacts++ took too long to answer. Try again.');
      } on ContactsPlusException {
        rethrow;
      } catch (_) {
        throw const ContactsPlusException('Couldn’t reach Contacts++. Check your connection and try again.');
      }
    }

    var response = await attempt(token);
    if (response.statusCode == 401 && token != null) {
      final renewed = await tokenRefresher?.call(token);
      if (renewed != null && renewed != token) response = await attempt(renewed);
      if (response.statusCode == 401) await onSessionRejected?.call();
    }
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw ContactsPlusException('Contacts++ sent an answer Messages++ couldn’t read.', statusCode: response.statusCode);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
    var message = 'Something went wrong. Please try again.';
    String? code;
    final errors = decoded['errors'];
    if (errors is Map && errors.values.isNotEmpty) {
      final first = errors.values.first;
      if (first is List && first.isNotEmpty) message = '${first.first}';
    } else if (errors is List && errors.isNotEmpty && errors.first is Map) {
      final first = errors.first as Map;
      message = '${first['message'] ?? message}';
      code = first['code'] as String?;
    } else if (decoded['message'] is String) {
      message = decoded['message'] as String;
    }
    throw ContactsPlusException(message, statusCode: response.statusCode, code: code);
  }
}
