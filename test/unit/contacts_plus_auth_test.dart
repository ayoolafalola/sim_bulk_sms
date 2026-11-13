import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sim_bulk_sms/platform/contacts_plus/contacts_plus_api.dart';
import 'package:sim_bulk_sms/platform/contacts_plus/contacts_plus_auth.dart';
import 'package:sim_bulk_sms/platform/contacts_plus/contacts_plus_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;
  late http.Response Function(http.Request) reply;

  ContactsPlusAuth auth() => ContactsPlusAuth(
        api: ContactsPlusApi(
          baseUrl: 'https://api.test/api/v1',
          client: MockClient((request) async {
            requests.add(request);
            return reply(request);
          }),
        ),
      );

  http.Response json(int status, Object body) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    requests = [];
    reply = (_) => json(500, {'errors': []});
  });

  test('sign-in opens Contacts++ with a PKCE challenge, state and only Messages++ scopes', () async {
    final uri = await auth().beginSignIn();

    expect(uri.host, 'contacts.comeriver.com');
    expect(uri.path, '/app-authorize');
    expect(uri.queryParameters['client_id'], 'messages-plus');
    expect(uri.queryParameters['redirect_uri'], 'https://contacts.comeriver.com/messages/auth/callback');
    expect(uri.queryParameters['code_challenge'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(uri.queryParameters['state'], matches(RegExp(r'^[A-Za-z0-9_-]{16,128}$')));
    expect(uri.queryParameters['scopes']!.split(' '), ContactsPlusConfig.scopes);
    expect(ContactsPlusConfig.scopes, isNot(contains('calls.manage')));
  });

  test('the callback is exchanged with the verifier and the account is kept', () async {
    final a = auth();
    final start = await a.beginSignIn();
    final state = start.queryParameters['state']!;
    reply = (_) => json(200, {
          'data': {
            'user': {'id': 'u-1', 'display_name': 'Ada', 'username': 'ada'},
            'tokens': {'access_token': 'access-1', 'refresh_token': 'refresh-1'},
            'scopes': ContactsPlusConfig.scopes,
          },
        });

    final account = await a.completeSignIn(Uri.parse('messagesplus://auth/callback?code=${'c' * 64}&state=$state'), platform: 'ios');

    expect(account.displayName, 'Ada');
    expect(await a.accessToken(), 'access-1');
    expect((await a.account())?.userId, 'u-1');
    final body = jsonDecode(requests.single.body) as Map;
    expect(requests.single.url.path, '/api/v1/auth/connected-app/token');
    expect(body['client_id'], 'messages-plus');
    expect(ContactsPlusAuth.pkceChallenge(body['code_verifier'] as String), start.queryParameters['code_challenge']);
  });

  test('a callback with the wrong state is refused without calling the server', () async {
    final a = auth();
    await a.beginSignIn();

    await expectLater(
      a.completeSignIn(Uri.parse('messagesplus://auth/callback?code=x&state=forged-state-value'), platform: 'android'),
      throwsA(isA<ContactsPlusException>()),
    );
    expect(requests, isEmpty);
    expect(await a.account(), isNull);
  });

  test('a cancelled approval says so and leaves the app signed out', () async {
    final a = auth();
    final state = (await a.beginSignIn()).queryParameters['state'];

    await expectLater(
      a.completeSignIn(Uri.parse('messagesplus://auth/callback?error=access_denied&state=$state'), platform: 'ios'),
      throwsA(isA<ContactsPlusException>().having((e) => e.message, 'message', contains('cancelled'))),
    );
    expect(await a.account(), isNull);
  });

  test('the verified sign-in link and the older app link are callbacks; lookalikes are not', () {
    expect(ContactsPlusAuth.isCallback(Uri.parse('https://contacts.comeriver.com/messages/auth/callback?code=a')), isTrue);
    expect(ContactsPlusAuth.isCallback(Uri.parse('messagesplus://auth/callback?code=a')), isTrue);
    for (final link in [
      'https://contacts.comeriver.com.evil.example/messages/auth/callback?code=a',
      'http://contacts.comeriver.com/messages/auth/callback?code=a',
      'https://contacts.comeriver.com/events/auth/callback?code=a',
      'messagesplus://messages/auth/callback?code=a',
    ]) {
      expect(ContactsPlusAuth.isCallback(Uri.parse(link)), isFalse, reason: link);
    }
  });

  test('an expired access token is refreshed once and the request retried', () async {
    FlutterSecureStorage.setMockInitialValues({'cpp_access_token': 'old', 'cpp_refresh_token': 'r-1'});
    final a = auth();
    reply = (request) {
      if (request.url.path.endsWith('/auth/refresh')) {
        return json(200, {
          'data': {
            'tokens': {'access_token': 'new', 'refresh_token': 'r-2'}
          },
        });
      }
      return request.headers['Authorization'] == 'Bearer new'
          ? json(200, {
              'data': {'ok': true}
            })
          : json(401, {
              'errors': [
                {'code': 'unauthenticated', 'message': 'Expired'}
              ]
            });
    };

    final result = await a.api.get('/connected-app/me', token: 'old');

    expect(result['data'], {'ok': true});
    expect(await a.accessToken(), 'new');
    expect(requests.map((r) => r.url.path), ['/api/v1/connected-app/me', '/api/v1/auth/refresh', '/api/v1/connected-app/me']);
  });

  test('a refused refresh signs out on the phone; being offline does not', () async {
    FlutterSecureStorage.setMockInitialValues({
      'cpp_access_token': 'old',
      'cpp_refresh_token': 'r-1',
      'cpp_account': jsonEncode({'id': 'u-1', 'display_name': 'Ada'}),
    });
    final offline = ContactsPlusAuth(
      api: ContactsPlusApi(baseUrl: 'https://api.test/api/v1', client: MockClient((_) => throw Exception('no network'))),
    );
    expect(await offline.refresh('old'), isNull);
    expect(await offline.account(), isNotNull);

    reply = (_) => json(401, {
          'errors': [
            {'code': 'invalid_refresh', 'message': 'Signed out'}
          ]
        });
    final refused = auth();
    expect(await refused.refresh('old'), isNull);
    expect(await refused.account(), isNull);
  });

  test('server errors become short, safe messages', () async {
    reply = (_) => json(403, {
          'errors': [
            {'code': 'insufficient_scope', 'message': 'Messages++ does not have permission to perform this action.'}
          ],
        });
    await expectLater(
      auth().api.get('/x', token: 't'),
      throwsA(isA<ContactsPlusException>().having((e) => e.code, 'code', 'insufficient_scope').having((e) => e.statusCode, 'status', 403)),
    );
  });
}
