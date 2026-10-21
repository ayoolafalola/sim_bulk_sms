import 'package:go_router/go_router.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/dashboard/dashboard_screen.dart';

final appRouter = GoRouter(routes: [
  GoRoute(path: '/', builder: (c, s) => const DashboardScreen()),
  GoRoute(path: '/contacts', builder: (c, s) => const ContactsScreen()),
]);
