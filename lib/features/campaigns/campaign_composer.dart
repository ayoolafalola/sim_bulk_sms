import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/group_repository.dart';
import '../../domain/models/contact.dart';
import '../../domain/services/campaign_planner.dart';

/// Turns a recipient selection (groups and/or individual contacts) into a
/// snapshot plan, and persists it as a `ready` campaign. The selection itself
/// is not stored: the snapshot is the campaign's only source of recipients.
class CampaignComposer {
  CampaignComposer({required this.contacts, required this.groups, required this.campaigns});
  final ContactRepository contacts;
  final GroupRepository groups;
  final CampaignRepository campaigns;

  /// Union of group members and individually picked contacts, each contact once.
  Future<List<Contact>> resolveSelection({required Set<int> groupIds, required Set<int> contactIds}) async {
    final byId = <int, Contact>{};
    for (final g in groupIds) {
      for (final c in await groups.members(g)) {
        byId[c.id!] = c;
      }
    }
    if (contactIds.isNotEmpty) {
      for (final c in await contacts.search()) {
        if (contactIds.contains(c.id)) byId[c.id!] = c;
      }
    }
    return byId.values.toList();
  }

  Future<SnapshotPlan> plan({
    required String template,
    required Set<int> groupIds,
    required Set<int> contactIds,
    Map<String, String> fallbacks = const {},
  }) async =>
      buildSnapshotPlan(
        template: template,
        contacts: await resolveSelection(groupIds: groupIds, contactIds: contactIds),
        suppressedE164: await contacts.suppressedNumbers(),
        fallbacks: fallbacks,
      );

  /// Creates (or rewrites an editable) campaign and saves its snapshot.
  /// Returns the campaign id. Refuses a plan that cannot be saved.
  Future<int> save({
    int? campaignId,
    required String name,
    required String template,
    required String platform,
    required SnapshotPlan plan,
  }) async {
    if (!plan.canSave) throw StateError('This campaign has blocked recipients or no recipients.');
    final id = campaignId ?? await campaigns.createDraft(name: name, template: template, platform: platform);
    if (campaignId != null) await campaigns.updateDraft(id, name: name, template: template);
    await campaigns.saveSnapshot(id, plan.recipients);
    return id;
  }
}
