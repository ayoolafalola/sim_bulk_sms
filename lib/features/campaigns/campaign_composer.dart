import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/group_repository.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/contact.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';

enum ResendMode {
  /// The exact people (and messages) of the earlier run, minus anyone who has
  /// since opted out or been suppressed.
  sameRecipients,
  /// Whoever is in the campaign's groups/contacts now, with fresh messages.
  currentAudience,
}

class ResendRefusedException implements Exception {
  ResendRefusedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Why a run could not be created; null fields on success.
class RunPlanResult {
  const RunPlanResult.created(int this.campaignId) : blocked = false, empty = false;
  const RunPlanResult.blocked() : campaignId = null, blocked = true, empty = false;
  const RunPlanResult.empty() : campaignId = null, blocked = false, empty = true;
  final int? campaignId;
  final bool blocked, empty;
}

/// Turns a recipient selection (groups and/or individual contacts) into a
/// snapshot plan and persists it as a `ready` campaign. The audience and
/// fallbacks are stored too, so the campaign can be edited, resent and
/// scheduled; each send still uses its own immutable snapshot.
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

  /// Plan for a saved campaign using its stored audience and fallbacks.
  Future<SnapshotPlan> planForCampaign(Campaign c) async {
    final a = await campaigns.audience(c.id);
    return plan(template: c.messageTemplate, groupIds: a.groupIds, contactIds: a.contactIds,
        fallbacks: await campaigns.fallbacks(c.id));
  }

  /// Creates (or rewrites an editable) campaign and saves its snapshot,
  /// audience and fallbacks. Returns the campaign id. Refuses a plan that cannot be saved.
  Future<int> save({
    int? campaignId,
    required String name,
    required String template,
    required String platform,
    required SnapshotPlan plan,
    CampaignAudience audience = const CampaignAudience(),
    Map<String, String> fallbacks = const {},
  }) async {
    if (!plan.canSave) throw StateError('This campaign has blocked recipients or no recipients.');
    final id = campaignId ??
        await campaigns.createDraft(name: name, template: template, platform: platform, fallbacks: fallbacks);
    if (campaignId != null) {
      await campaigns.updateDraft(id, name: name, template: template);
      await campaigns.saveFallbacks(id, fallbacks);
    }
    await campaigns.saveAudience(id, audience);
    await campaigns.saveSnapshot(id, plan.recipients);
    return id;
  }

  /// "Send again": a new ready campaign copied from [sourceId]. The original
  /// and its report are never changed.
  Future<int> resend(int sourceId, ResendMode mode, {required String platform}) async {
    final src = await campaigns.get(sourceId);
    if (src == null) throw ResendRefusedException('The original campaign no longer exists.');
    final List<SnapshotRecipient> recipients;
    if (mode == ResendMode.sameRecipients) {
      final suppressed = await contacts.suppressedNumbers();
      final optedOut = {for (final c in await contacts.search()) if (c.consent == ConsentStatus.optedOut) c.id};
      recipients = [
        for (final r in await campaigns.recipients(sourceId))
          if (!suppressed.contains(r.phone) && !optedOut.contains(r.contactId))
            SnapshotRecipient(contactId: r.contactId, name: r.name, phoneE164: r.phone, renderedMessage: r.renderedMessage),
      ];
    } else {
      final p = await planForCampaign(src);
      if (p.blocked.isNotEmpty) {
        throw ResendRefusedException('Some recipients have no value for '
            '${p.unresolvedVariables.map((v) => '{$v}').join(', ')}. Edit the campaign to add a fallback.');
      }
      recipients = p.recipients;
    }
    if (recipients.isEmpty) throw ResendRefusedException('No one in this campaign can be messaged now.');
    return _copy(src, name: '${src.name} (again)', recipients: recipients, platform: platform);
  }

  /// A scheduled occurrence: fresh snapshot from the campaign's current audience.
  Future<RunPlanResult> createScheduledRun(Campaign src,
      {required int scheduleId, required String label, required String platform}) async {
    final p = await planForCampaign(src);
    if (p.blocked.isNotEmpty) return const RunPlanResult.blocked();
    if (p.recipients.isEmpty) return const RunPlanResult.empty();
    return RunPlanResult.created(await _copy(src,
        name: '${src.name} · $label', recipients: p.recipients, platform: platform, scheduleId: scheduleId));
  }

  Future<int> _copy(Campaign src,
      {required String name, required List<SnapshotRecipient> recipients, required String platform, int? scheduleId}) async {
    final id = await campaigns.createDraft(
        name: name, template: src.messageTemplate, platform: platform,
        sourceCampaignId: src.id, scheduleId: scheduleId, fallbacks: await campaigns.fallbacks(src.id));
    await campaigns.saveAudience(id, await campaigns.audience(src.id));
    await campaigns.saveSnapshot(id, recipients);
    return id;
  }
}
