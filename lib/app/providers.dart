import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show Database;
import '../data/repositories/campaign_repository.dart';
import '../data/repositories/contact_repository.dart';
import '../data/repositories/group_repository.dart';
import '../domain/models/campaign.dart';
import '../domain/models/contact.dart';
import '../domain/models/statuses.dart';

/// Overridden in main() with the opened database (and in tests).
final databaseProvider = Provider<Database>((ref) => throw UnimplementedError('databaseProvider not overridden'));

final contactRepositoryProvider = Provider((ref) => ContactRepository(ref.watch(databaseProvider)));
final groupRepositoryProvider = Provider((ref) => GroupRepository(ref.watch(databaseProvider)));
final campaignRepositoryProvider = Provider((ref) => CampaignRepository(ref.watch(databaseProvider)));

/// Bump after any write so dependent providers refetch.
final dataVersionProvider = StateProvider<int>((ref) => 0);

final contactSearchProvider = StateProvider<String>((ref) => '');

final contactsProvider = FutureProvider<List<Contact>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(contactRepositoryProvider).search(ref.watch(contactSearchProvider));
});

final groupsProvider = FutureProvider<List<GroupSummary>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(groupRepositoryProvider).list();
});

class DashboardStats {
  const DashboardStats({required this.contacts, required this.groups, required this.drafts, required this.recent});
  final int contacts, groups, drafts;
  final List<Campaign> recent;
}

/// Every figure is derived from persisted data (FR-01).
final dashboardStatsProvider = FutureProvider<DashboardStats>((ref) async {
  ref.watch(dataVersionProvider);
  final campaigns = ref.watch(campaignRepositoryProvider);
  return DashboardStats(
    contacts: await ref.watch(contactRepositoryProvider).count(),
    groups: await ref.watch(groupRepositoryProvider).count(),
    drafts: await campaigns.countByStatus(CampaignStatus.draft),
    recent: await campaigns.recent(),
  );
});
