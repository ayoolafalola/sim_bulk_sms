import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/campaigns/campaign_detail_screen.dart';
import '../features/campaigns/campaign_editor_screen.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/contacts/csv_import_screen.dart';
import '../features/contacts/import_phone_contacts_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/groups/group_detail_screen.dart';
import '../features/groups/groups_screen.dart';
import '../features/scheduling/schedule_editor_screen.dart';
import '../features/settings/background_setup_screen.dart';
import '../features/settings/send_settings_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/setup/onboarding_screen.dart';

Widget _withId(GoRouterState s, Widget Function(int id) build) {
  final id = int.tryParse(s.pathParameters['id'] ?? '');
  return id == null ? const Scaffold(body: Center(child: Text('Not found.'))) : build(id);
}

/// Everything is nested under '/' so each screen gets a back button to the dashboard.
final appRouter = GoRouter(routes: [
  GoRoute(path: '/welcome', builder: (c, s) => const OnboardingScreen()),
  GoRoute(path: '/', builder: (c, s) => const DashboardScreen(), routes: [
    GoRoute(path: 'contacts', builder: (c, s) => const ContactsScreen(), routes: [
      GoRoute(
          path: 'import-csv',
          builder: (c, s) => s.extra is CsvImportArgs
              ? CsvImportScreen(args: s.extra! as CsvImportArgs)
              : const Scaffold(body: Center(child: Text('Pick a CSV file from Contacts to import.')))),
      GoRoute(
          path: 'import',
          builder: (c, s) =>
              ImportPhoneContactsScreen(groupId: int.tryParse(s.uri.queryParameters['group'] ?? ''))),
    ]),
    GoRoute(path: 'groups', builder: (c, s) => const GroupsScreen(), routes: [
      GoRoute(path: ':id', builder: (c, s) => _withId(s, (id) => GroupDetailScreen(groupId: id))),
    ]),
    GoRoute(path: 'settings', builder: (c, s) => const SettingsScreen(), routes: [
      GoRoute(path: 'send', builder: (c, s) => const SendSettingsScreen()),
      GoRoute(path: 'setup', builder: (c, s) => const AppSetupScreen()),
      GoRoute(path: 'background', builder: (c, s) => const AppSetupScreen()), // older links
    ]),
    GoRoute(path: 'campaigns/new', builder: (c, s) => const CampaignEditorScreen()),
    GoRoute(path: 'campaigns/:id', builder: (c, s) => _withId(s, (id) => CampaignDetailScreen(campaignId: id)), routes: [
      GoRoute(path: 'edit', builder: (c, s) => _withId(s, (id) => CampaignEditorScreen(campaignId: id))),
      GoRoute(path: 'schedule', builder: (c, s) => _withId(s, (id) => ScheduleEditorScreen(campaignId: id))),
    ]),
  ]),
]);
