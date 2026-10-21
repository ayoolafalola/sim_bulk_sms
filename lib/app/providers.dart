import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show Database;
import '../data/repositories/campaign_repository.dart';
import '../data/repositories/contact_repository.dart';
import '../data/repositories/group_repository.dart';
import '../domain/models/campaign.dart';
import '../domain/models/contact.dart';
import '../domain/models/statuses.dart';
import '../features/campaigns/campaign_composer.dart';
import '../platform/contacts/phone_contacts_service.dart';

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

final composerProvider = Provider((ref) => CampaignComposer(
      contacts: ref.watch(contactRepositoryProvider),
      groups: ref.watch(groupRepositoryProvider),
      campaigns: ref.watch(campaignRepositoryProvider),
    ));

final allContactsProvider = FutureProvider<List<Contact>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(contactRepositoryProvider).search();
});

final groupMembersProvider = FutureProvider.family<List<Contact>, int>((ref, groupId) {
  ref.watch(dataVersionProvider);
  return ref.watch(groupRepositoryProvider).members(groupId);
});

final campaignProvider = FutureProvider.family<Campaign?, int>((ref, id) {
  ref.watch(dataVersionProvider);
  return ref.watch(campaignRepositoryProvider).get(id);
});

final campaignRecipientsProvider = FutureProvider.family<List<CampaignRecipient>, int>((ref, id) {
  ref.watch(dataVersionProvider);
  return ref.watch(campaignRepositoryProvider).recipients(id);
});

final phoneContactsServiceProvider = Provider<PhoneContactsService>((ref) => NativePhoneContactsService());
