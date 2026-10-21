import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/domain/models/campaign.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Contact c(String name, String phone, {ConsentStatus consent = ConsentStatus.unknown, String? email}) =>
    Contact(name: name, phoneRaw: phone, phoneNormalized: phone, email: email, consent: consent);

void main() {
  sqfliteFfiInit();

  group('buildSnapshotPlan (pure)', () {
    test('renders, excludes suppressed/opted-out, estimates', () {
      final plan = buildSnapshotPlan(
        template: 'Hi {first_name}',
        contacts: [c('Ada L', '+2341'), c('Bob', '+2342'), c('Cy', '+2343', consent: ConsentStatus.optedOut)],
        suppressedE164: {'+2342'},
      );
      expect(plan.recipients.map((r) => r.renderedMessage), ['Hi Ada']);
      expect(plan.eligibility.excludedCount, 2);
      expect(plan.estimate.totalSegments, 1);
      expect(plan.canSave, true);
    });
    test('unresolved variable blocks saving and names the variable', () {
      final plan = buildSnapshotPlan(template: 'Hi {first_name} {event_name}', contacts: [c('Ada', '+2341')], suppressedE164: {});
      expect(plan.canSave, false);
      expect(plan.unresolvedVariables, {'event_name'});
      expect(plan.recipients, isEmpty);
    });
    test('fallback resolves it', () {
      final plan = buildSnapshotPlan(template: '{event_name}', contacts: [c('Ada', '+2341')],
          suppressedE164: {}, fallbacks: {'event_name': 'our event'});
      expect(plan.canSave, true);
    });
    test('Unicode message is counted and flagged', () {
      final plan = buildSnapshotPlan(template: 'Hi {name} ✓', contacts: [c('Ada', '+2341')], suppressedE164: {});
      expect(plan.estimate.unicodeMessages, 1);
    });
    test('unknown-consent recipients are counted for the review screen', () {
      final plan = buildSnapshotPlan(template: 'x', contacts: [c('A', '+1'), c('B', '+2', consent: ConsentStatus.optedIn)], suppressedE164: {});
      expect(plan.unknownConsentCount, 1);
    });
  });

  group('repositories (in-memory SQLite)', () {
    late Database db;
    late ContactRepository contacts;
    late GroupRepository groups;
    late CampaignRepository campaigns;
    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      contacts = ContactRepository(db); groups = GroupRepository(db); campaigns = CampaignRepository(db);
    });
    tearDown(() => db.close());

    test('groups: membership, multi-group, idempotent add, counts', () async {
      final a = await contacts.add(c('Ada', '+2341'));
      final b = await contacts.add(c('Bob', '+2342'));
      final g1 = await groups.create('Choir'), g2 = await groups.create('Board');
      await groups.addContacts(g1, [a, b]);
      await groups.addContacts(g1, [a]); // no-op
      await groups.addContacts(g2, [a]);
      final list = await groups.list();
      expect(list.firstWhere((g) => g.id == g1).memberCount, 2);
      expect((await groups.members(g2)).single.name, 'Ada');
      await groups.removeContact(g1, b);
      expect((await groups.members(g1)).length, 1);
    });

    test('snapshot survives contact edits, contact deletion and group deletion', () async {
      final a = await contacts.add(c('Ada', '+2341'));
      final g = await groups.create('G');
      await groups.addContacts(g, [a]);
      final id = await campaigns.createDraft(name: 'N', template: 'Hi {name}', platform: 'android');
      final plan = buildSnapshotPlan(template: 'Hi {name}',
          contacts: [(await contacts.search()).single], suppressedE164: {});
      await campaigns.saveSnapshot(id, plan.recipients);

      await contacts.update(Contact(id: a, name: 'Changed', phoneRaw: 'x', phoneNormalized: '+9999'));
      await contacts.delete(a);
      await groups.delete(g);

      final r = (await campaigns.recipients(id)).single;
      expect([r.name, r.phone, r.renderedMessage], ['Ada', '+2341', 'Hi Ada']);
      expect(r.contactId, isNull); // ON DELETE SET NULL
      expect((await campaigns.get(id))!.recipientCount, 1);
      expect((await campaigns.get(id))!.status, CampaignStatus.ready);
    });

    test('snapshot is locked once the campaign is running', () async {
      final id = await campaigns.createDraft(name: 'N', template: 't', platform: 'android');
      await campaigns.saveSnapshot(id, const [SnapshotRecipient(name: 'A', phoneE164: '+1', renderedMessage: 't')]);
      await campaigns.setStatus(id, CampaignStatus.running);
      expect(() => campaigns.saveSnapshot(id, const []), throwsA(isA<SnapshotLockedException>()));
      expect(() => campaigns.updateDraft(id, name: 'x', template: 'y'), throwsA(isA<SnapshotLockedException>()));
      expect((await campaigns.recipients(id)).length, 1);
    });

    test('editing the template clears the snapshot and returns to draft', () async {
      final id = await campaigns.createDraft(name: 'N', template: 't', platform: 'ios');
      await campaigns.saveSnapshot(id, const [SnapshotRecipient(name: 'A', phoneE164: '+1', renderedMessage: 't')]);
      await campaigns.updateDraft(id, name: 'N2', template: 'new');
      expect((await campaigns.recipients(id)), isEmpty);
      expect((await campaigns.get(id))!.status, CampaignStatus.draft);
    });

    test('1,000-recipient snapshot persists with status counts', () async {
      final id = await campaigns.createDraft(name: 'Big', template: 'x', platform: 'android');
      await campaigns.saveSnapshot(id, [for (var i = 0; i < 1000; i++)
        SnapshotRecipient(name: 'C$i', phoneE164: '+2348${10000000 + i}', renderedMessage: 'x')]);
      expect((await campaigns.statusCounts(id))[RecipientStatus.pending], 1000);
    });
  });

  group('providers', () {
    test('dashboard stats derive from the database', () async {
      final db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      addTearDown(db.close);
      final container = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
      addTearDown(container.dispose);
      await container.read(contactRepositoryProvider).add(c('Ada', '+2341'));
      await container.read(groupRepositoryProvider).create('G');
      await container.read(campaignRepositoryProvider).createDraft(name: 'D', template: 't', platform: 'android');
      final s = await container.read(dashboardStatsProvider.future);
      expect([s.contacts, s.groups, s.drafts, s.recent.length], [1, 1, 1, 1]);
    });
  });
}
