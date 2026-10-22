import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show Database;
import '../data/repositories/attempt_repository.dart';
import '../data/repositories/campaign_repository.dart';
import '../data/repositories/contact_repository.dart';
import '../data/repositories/group_repository.dart';
import '../data/repositories/schedule_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../domain/models/campaign.dart';
import '../domain/models/contact.dart';
import '../domain/models/schedule.dart';
import '../domain/models/send_settings.dart';
import '../domain/models/statuses.dart';
import '../features/campaigns/campaign_composer.dart';
import '../features/scheduling/schedule_runner.dart';
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
  const DashboardStats({
    required this.contacts, required this.groups, required this.drafts, required this.recent,
    this.sentThisWeek = 0, this.deliveredThisWeek = 0, this.progress = const {},
  });
  final int contacts, groups, drafts;
  /// Newest first, drafts included.
  final List<Campaign> recent;
  /// Messages handed to the carrier / Messages app in the last 7 days, and how many were reported delivered.
  final int sentThisWeek, deliveredThisWeek;
  /// Recipient status counts per recent campaign id (for progress bars).
  final Map<int, Map<RecipientStatus, int>> progress;
}

/// Every figure is derived from persisted data (FR-01).
final dashboardStatsProvider = FutureProvider<DashboardStats>((ref) async {
  ref.watch(dataVersionProvider);
  final campaigns = ref.watch(campaignRepositoryProvider);
  final recent = await campaigns.recent(limit: 20);
  final week = await AttemptRepository(ref.watch(databaseProvider))
      .statusCountsSince(DateTime.now().subtract(const Duration(days: 7)));
  return DashboardStats(
    contacts: await ref.watch(contactRepositoryProvider).count(),
    groups: await ref.watch(groupRepositoryProvider).count(),
    drafts: await campaigns.countByStatus(CampaignStatus.draft),
    recent: recent,
    sentThisWeek: (week[RecipientStatus.submitted] ?? 0) + (week[RecipientStatus.sent] ?? 0) +
        (week[RecipientStatus.delivered] ?? 0),
    deliveredThisWeek: week[RecipientStatus.delivered] ?? 0,
    progress: {
      for (final c in recent)
        if (c.status != CampaignStatus.draft) c.id: await campaigns.statusCounts(c.id),
    },
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

final scheduleRepositoryProvider = Provider((ref) => ScheduleRepository(ref.watch(databaseProvider)));

final schedulesProvider = FutureProvider<List<ScheduleListItem>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(scheduleRepositoryProvider).list();
});

final campaignScheduleProvider = FutureProvider.family<CampaignSchedule?, int>((ref, campaignId) {
  ref.watch(dataVersionProvider);
  return ref.watch(scheduleRepositoryProvider).forCampaign(campaignId);
});

final campaignAudienceProvider = FutureProvider.family<CampaignAudience, int>((ref, campaignId) {
  ref.watch(dataVersionProvider);
  return ref.watch(campaignRepositoryProvider).audience(campaignId);
});

final scheduleRunnerProvider = Provider((ref) => ScheduleRunner(
      schedules: ref.watch(scheduleRepositoryProvider),
      campaigns: ref.watch(campaignRepositoryProvider),
      composer: ref.watch(composerProvider),
    ));

final settingsRepositoryProvider = Provider((ref) => SettingsRepository(ref.watch(databaseProvider)));

final sendSettingsProvider = FutureProvider<SendSettings>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(settingsRepositoryProvider).load();
});

/// First-launch setup finished (or skipped through to the end).
final onboardingDoneProvider = FutureProvider<bool>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(settingsRepositoryProvider).flag('onboarding_done');
});

/// Campaigns deleted with Undo still available: hidden until really deleted.
final pendingCampaignDeletesProvider = StateProvider<Set<int>>((ref) => const {});
