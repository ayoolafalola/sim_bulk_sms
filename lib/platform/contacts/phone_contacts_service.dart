import 'package:flutter/services.dart';

/// One phone number of a contact in the phone's address book.
class PhoneContact {
  const PhoneContact({required this.name, required this.phone});
  final String name, phone;
}

/// Read-only access to the phone's contacts (names and numbers only).
abstract class PhoneContactsService {
  Future<bool> hasPermission();
  Future<bool> requestPermission();
  Future<List<PhoneContact>> load();
}

class NativePhoneContactsService implements PhoneContactsService {
  static const _ch = MethodChannel('app.sim_bulk_sms/contacts');

  @override
  Future<bool> hasPermission() async => (await _ch.invokeMethod<bool>('hasPermission')) ?? false;

  @override
  Future<bool> requestPermission() async => (await _ch.invokeMethod<bool>('requestPermission')) ?? false;

  @override
  Future<List<PhoneContact>> load() async {
    final list = await _ch.invokeMethod<List<dynamic>>('getPhoneContacts') ?? const [];
    return [
      for (final e in list)
        PhoneContact(name: (e as Map)['name'] as String? ?? '', phone: e['phone'] as String? ?? ''),
    ];
  }
}
