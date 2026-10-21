import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/contact_repository.dart';
import 'package:sim_bulk_sms/data/repositories/group_repository.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/features/campaigns/campaign_composer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Database db;
  late ContactRepository contacts;
  late GroupRepository groups;
  late CampaignRepository campaigns;
  late CampaignComposer composer;

  Future<int> add(String name, String phone, {ConsentStatus consent = ConsentStatus.unknown}) =>
      contacts.add(Contact(name: name, phoneRaw: phone, phoneNormalized: phone, consent: consent));

  setUp(() async {
    db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    contacts = ContactRepository(db);
    groups = GroupRepository(db);
    campaigns = CampaignRepository(db);
    composer = CampaignComposer(contacts: contacts, groups: groups, campaigns: campaigns);
  });
  tearDown(() => db.close());

  test('group members and individual picks are merged, each contact once', () async {
    final a = await add('Ada', '+2341'), b = await add('Bob', '+2342'), c = await add('Cy', '+2343');
    final g = await groups.create('G');
    await groups.addContacts(g, [a, b]);
    final sel = await composer.resolveSelection(groupIds: {g}, contactIds: {b, c});
    expect(sel.map((x) => x.name).toSet(), {'Ada', 'Bob', 'Cy'});
  });

  test('plan excludes suppressed and opted-out contacts', () async {
    final a = await add('Ada', '+2341'), b = await add('Bob', '+2342');
    final c = await add('Cy', '+2343', consent: ConsentStatus.optedOut);
    await contacts.suppress('+2342');
    final plan = await composer.plan(template: 'Hi {first_name}', groupIds: {}, contactIds: {a, b, c});
    expect(plan.recipients.map((r) => r.renderedMessage), ['Hi Ada']);
    expect(plan.eligibility.excludedSuppressed, hasLength(1));
    expect(plan.eligibility.excludedOptedOut, hasLength(1));
  });

  test('save creates a ready campaign with the snapshot', () async {
    final a = await add('Ada Love', '+2341');
    final plan = await composer.plan(template: 'Hi {first_name}', groupIds: {}, contactIds: {a});
    final id = await composer.save(name: 'Launch', template: 'Hi {first_name}', platform: 'android', plan: plan);
    final c = (await campaigns.get(id))!;
    expect(c.status, CampaignStatus.ready);
    expect(c.recipientCount, 1);
    expect((await campaigns.recipients(id)).single.renderedMessage, 'Hi Ada');
  });

  test('saving an existing campaign replaces its template and snapshot', () async {
    final a = await add('Ada', '+2341'), b = await add('Bob', '+2342');
    final p1 = await composer.plan(template: 'One', groupIds: {}, contactIds: {a});
    final id = await composer.save(name: 'C', template: 'One', platform: 'android', plan: p1);
    final p2 = await composer.plan(template: 'Two {first_name}', groupIds: {}, contactIds: {a, b});
    expect(await composer.save(campaignId: id, name: 'C2', template: 'Two {first_name}', platform: 'android', plan: p2), id);
    final c = (await campaigns.get(id))!;
    expect(c.name, 'C2');
    expect(c.messageTemplate, 'Two {first_name}');
    expect((await campaigns.recipients(id)).map((r) => r.renderedMessage), ['Two Ada', 'Two Bob']);
  });

  test('a plan with unresolved variables cannot be saved', () async {
    final a = await add('Ada', '+2341');
    final plan = await composer.plan(template: '{event_name}', groupIds: {}, contactIds: {a});
    expect(() => composer.save(name: 'C', template: '{event_name}', platform: 'android', plan: plan), throwsStateError);
    expect(await campaigns.recent(), isEmpty);
  });

  test('fallbacks resolve missing variables', () async {
    final a = await add('Ada', '+2341');
    final plan = await composer.plan(template: 'See you at {event_name}', groupIds: {}, contactIds: {a},
        fallbacks: {'event_name': 'the fair'});
    expect(plan.canSave, true);
    expect(plan.recipients.single.renderedMessage, 'See you at the fair');
  });
}
