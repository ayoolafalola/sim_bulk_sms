import 'package:flutter/services.dart';
import '../../domain/models/contact.dart';

/// One phone number of a contact in the phone's address book.
class PhoneContact {
  const PhoneContact({required this.name, required this.phone});
  final String name, phone;
}

/// One number/email/date of a phone contact, as the phone labels it.
class SyncedValue {
  const SyncedValue({required this.value, this.label, this.type = 0, this.primary = false, this.kind});
  final String value;
  final String? label;
  /// Android type code (2 = Mobile for numbers); 0 when unknown.
  final int type;
  /// Marked as the default on the phone.
  final bool primary;
  /// For dates: birthday, anniversary or other.
  final String? kind;
}

/// A phone contact in the phone's own format.
class SyncedContact {
  const SyncedContact({
    required this.contactId, required this.lookupKey, required this.name, this.givenName, this.familyName,
    this.phones = const [], this.emails = const [], this.dates = const [],
    this.organization, this.jobTitle, this.address, this.note,
  });
  final int contactId;
  final String lookupKey, name;
  final String? givenName, familyName, organization, jobTitle, address, note;
  final List<SyncedValue> phones, emails, dates;
}

/// Phone contacts changed since the last sync (or all of them when [full]),
/// plus the ids of contacts deleted since then.
class ContactsSnapshot {
  const ContactsSnapshot({required this.contacts, this.deleted = const [], required this.now, required this.full});
  final List<SyncedContact> contacts;
  final List<int> deleted;
  /// Phone clock (ms) when read: the next sync asks for changes after this.
  final int now;
  final bool full;
}

/// Read-only access to the phone's contacts.
abstract class PhoneContactsService {
  Future<bool> hasPermission();
  Future<bool> requestPermission();
  /// One entry per number (for quick pickers).
  Future<List<PhoneContact>> load();
  /// The full contact format for syncing; [since] 0 = everything.
  Future<ContactsSnapshot> sync({int since = 0});
  /// Opens the contact in the phone's Contacts app to edit. False if not possible.
  Future<bool> edit(Contact contact);
}

class NativePhoneContactsService implements PhoneContactsService {
  static const _ch = MethodChannel('app.sim_bulk_sms/contacts');

  @override
  Future<bool> hasPermission() async => (await _ch.invokeMethod<bool>('hasPermission')) ?? false;

  @override
  Future<bool> requestPermission() async => (await _ch.invokeMethod<bool>('requestPermission')) ?? false;

  @override
  Future<ContactsSnapshot> sync({int since = 0}) async {
    final m = Map<String, dynamic>.from(await _ch.invokeMethod('syncContacts', {'since': since}) as Map);
    List<SyncedValue> values(Object? list, {bool dates = false}) => [
          for (final v in (list as List? ?? const []).cast<Map<dynamic, dynamic>>())
            SyncedValue(
              value: '${v['value']}', label: v['label'] as String?, type: (v['type'] as num?)?.toInt() ?? 0,
              primary: v['primary'] == true, kind: dates ? v['kind'] as String? : null),
        ];
    return ContactsSnapshot(
      contacts: [
        for (final c in (m['contacts'] as List? ?? const []).cast<Map<dynamic, dynamic>>())
          SyncedContact(
            contactId: (c['contactId'] as num?)?.toInt() ?? 0,
            lookupKey: '${c['lookupKey'] ?? c['contactId']}',
            name: c['name'] as String? ?? '',
            givenName: c['given'] as String?, familyName: c['family'] as String?,
            phones: values(c['phones']), emails: values(c['emails']), dates: values(c['dates'], dates: true),
            organization: c['organization'] as String?, jobTitle: c['jobTitle'] as String?,
            address: c['address'] as String?, note: c['note'] as String?,
          ),
      ],
      deleted: [for (final d in (m['deleted'] as List? ?? const [])) (d as num).toInt()],
      now: (m['now'] as num).toInt(),
      full: m['full'] == true,
    );
  }

  @override
  Future<bool> edit(Contact contact) async =>
      await _ch.invokeMethod<bool>('editContact', {'contactId': contact.phoneContactId, 'lookupKey': contact.lookupKey}) ??
      false;

  @override
  Future<List<PhoneContact>> load() async {
    final list = await _ch.invokeMethod<List<dynamic>>('getPhoneContacts') ?? const [];
    return [
      for (final e in list)
        PhoneContact(name: (e as Map)['name'] as String? ?? '', phone: e['phone'] as String? ?? ''),
    ];
  }
}
