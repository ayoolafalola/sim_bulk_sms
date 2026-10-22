import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/campaigns/campaign_detail_screen.dart';
import '../features/campaigns/campaign_editor_screen.dart';
import '../features/contacts/contact_screen.dart';
import '../features/pro/pro_screen.dart';
import '../features/settings/email_settings_screen.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/contacts/csv_import_screen.dart';
import '../features/contacts/import_phone_contacts_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/groups/group_detail_screen.dart';
import '../features/messages/conversation_screen.dart';
import '../features/messages/messages_screen.dart';
import '../features/messages/new_message_screen.dart';
import '../features/scheduling/schedule_editor_screen.dart';
import '../features/settings/background_setup_screen.dart';
import '../features/settings/send_settings_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/setup/onboarding_screen.dart';
import 'app_shell.dart';

Widget _withId(GoRouterState s, Widget Function(int id) build) {
  final id = int.tryParse(s.pathParameters['id'] ?? '');
  return id == null ? const Scaffold(body: Center(child: Text('Not found.'))) : build(id);
}

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Tabs (Messages · Campaigns · Contacts · Settings) live in a shell with a bottom
/// navigation bar and keep their own history. Detail and form screens open
/// full screen above it (no bottom bar), with a back button to the tab.
final appRouter = GoRouter(navigatorKey: rootNavigatorKey, initialLocation: '/messages', routes: [
  GoRoute(path: '/welcome', builder: (c, s) => const OnboardingScreen()),
  StatefulShellRoute.indexedStack(
    builder: (c, s, shell) => AppShell(shell: shell),
    branches: [
      StatefulShellBranch(routes: [
        GoRoute(path: '/messages', builder: (c, s) => const MessagesScreen(), routes: [
          GoRoute(path: 'new', parentNavigatorKey: rootNavigatorKey, builder: (c, s) => const NewMessageScreen()),
          GoRoute(
              path: 'thread/:id',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) => _withId(s, (id) => ConversationScreen(threadId: id))),
          // A number to text (from another app or a notification), with an optional draft.
          GoRoute(
              path: 'compose',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) => ConversationScreen(
                  address: s.uri.queryParameters['to'], draft: s.uri.queryParameters['body'])),
        ]),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: '/', builder: (c, s) => const DashboardScreen(), routes: [
          GoRoute(
              path: 'campaigns/new',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) => const CampaignEditorScreen()),
          GoRoute(
              path: 'campaigns/:id',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) => _withId(s, (id) => CampaignDetailScreen(campaignId: id)),
              routes: [
                GoRoute(
                    path: 'edit',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (c, s) => _withId(s, (id) => CampaignEditorScreen(campaignId: id))),
                GoRoute(
                    path: 'schedule',
                    parentNavigatorKey: rootNavigatorKey,
                    builder: (c, s) => _withId(s, (id) => ScheduleEditorScreen(campaignId: id))),
              ]),
        ]),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: '/contacts', builder: (c, s) => const ContactsScreen(), routes: [
          GoRoute(
              path: 'import-csv',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) => s.extra is CsvImportArgs
                  ? CsvImportScreen(args: s.extra! as CsvImportArgs)
                  : const Scaffold(body: Center(child: Text('Pick a CSV file from Contacts to import.')))),
          GoRoute(
              path: 'import',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) =>
                  ImportPhoneContactsScreen(groupId: int.tryParse(s.uri.queryParameters['group'] ?? ''))),
          GoRoute(
              path: 'person/:id',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) => _withId(s, (id) => ContactScreen(contactId: id))),
        ]),
        // The Contacts tab with its Groups view selected.
        GoRoute(path: '/groups', builder: (c, s) => const ContactsScreen(showGroups: true), routes: [
          GoRoute(
              path: ':id',
              parentNavigatorKey: rootNavigatorKey,
              builder: (c, s) => _withId(s, (id) => GroupDetailScreen(groupId: id))),
        ]),
      ]),
      StatefulShellBranch(routes: [
        GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen(), routes: [
          GoRoute(path: 'send', parentNavigatorKey: rootNavigatorKey, builder: (c, s) => const SendSettingsScreen()),
          GoRoute(path: 'email', parentNavigatorKey: rootNavigatorKey, builder: (c, s) => const EmailSettingsScreen()),
          GoRoute(path: 'pro', parentNavigatorKey: rootNavigatorKey, builder: (c, s) => const ProScreen()),
          GoRoute(path: 'setup', parentNavigatorKey: rootNavigatorKey, builder: (c, s) => const AppSetupScreen()),
          // Older links.
          GoRoute(path: 'background', parentNavigatorKey: rootNavigatorKey, builder: (c, s) => const AppSetupScreen()),
        ]),
      ]),
    ],
  ),
]);
