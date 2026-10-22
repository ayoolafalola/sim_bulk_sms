import 'dart:io' show Platform;
import 'package:google_sign_in/google_sign_in.dart';
import '../../app/google_config.dart';
import 'gmail_sender.dart';

const gmailSendScope = 'https://www.googleapis.com/auth/gmail.send';

/// OAuth client ids: lib/app/google_config.dart (docs/GMAIL_SETUP.md).
const _serverClientId = googleWebClientId;
const _iosClientId = googleIosClientId;

/// Whether this build was given the Google client ids Gmail needs.
bool get gmailAvailable =>
    (Platform.isAndroid && _serverClientId.isNotEmpty) || (Platform.isIOS && _iosClientId.isNotEmpty);

/// Gmail through Google sign-in, with only the send-mail permission.
class GoogleGmailAuth implements GmailAuth {
  static Future<void>? _init;
  static Future<void> _ensure() => _init ??= GoogleSignIn.instance.initialize(
        clientId: _iosClientId.isEmpty ? null : _iosClientId,
        serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
      );

  /// Signs in and asks for the send permission. Returns the Gmail address.
  Future<String> connect() async {
    await _ensure();
    final account = await GoogleSignIn.instance.authenticate(scopeHint: const [gmailSendScope]);
    await account.authorizationClient.authorizeScopes(const [gmailSendScope]);
    return account.email;
  }

  @override
  Future<String?> token() async {
    try {
      await _ensure();
      final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
      final client = account?.authorizationClient ?? GoogleSignIn.instance.authorizationClient;
      return (await client.authorizationForScopes(const [gmailSendScope]))?.accessToken;
    } catch (_) {
      return null; // e.g. no screen to sign in on (background): the user must open the app
    }
  }

  @override
  Future<void> clear(String token) async {
    try {
      await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(accessToken: token);
    } catch (_) {}
  }

  Future<void> disconnect() async {
    try {
      await _ensure();
      await GoogleSignIn.instance.disconnect();
    } catch (_) {}
  }
}
