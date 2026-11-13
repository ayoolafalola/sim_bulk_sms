/// Messages++ signs in with a Contacts++ account as a scoped "connected app"
/// (the same PKCE handoff Events++ uses). The backend re-checks the client,
/// callback and permissions in `contacts/backend/config/contacts.php`.
abstract final class ContactsPlusConfig {
  static const clientId = 'messages-plus';

  /// Contacts++ returns the sign-in here: a verified link that only
  /// Messages++ can open (contacts.comeriver.com/messages/*, iOS associated
  /// domains and Android verified app links), so no other app can catch the
  /// one-time code. `messagesplus://auth/callback` still works for older
  /// builds and for the website's "Open Messages++" fallback.
  static const redirectUri = 'https://contacts.comeriver.com/messages/auth/callback';
  static const callbackScheme = 'messagesplus';

  /// Links between the Comeriver apps are addresses on this site: the
  /// installed app opens them, and the site guides people without it.
  static const contactsWeb = 'https://contacts.comeriver.com';
  static const messagesWeb = 'https://messages.comeriver.com';

  static const apiBaseUrl = String.fromEnvironment(
    'CONTACTS_API_BASE_URL',
    defaultValue: 'https://s1199.comeriver.com/api/v1',
  );

  /// What Messages++ asks for. Calling, Safe Circle, the phonebook and the
  /// developer API are never requested by the app.
  static const scopes = <String>[
    'profile.basic.read',
    'session.manage',
    'contacts.lookup',
    'messages.read',
    'messages.send',
    'backup.read',
    'backup.write',
    'relay.execute',
    'invitations.send',
    'activities.read',
  ];
}
