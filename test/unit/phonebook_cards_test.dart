import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/features/phonebook/phonebook_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('one card per phone contact, with every international number; app-only contacts are left out', () async {
    final db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
    const now = '2026-11-11';
    final bola = await db.insert('contacts', {
      'name': 'Bola', 'phone_raw': '0803 111 1111', 'phone_normalized': '+2348031111111', 'source': 'phone',
      'phone_contact_id': 42, 'created_at': now, 'updated_at': now,
    });
    await db.insert('contact_phones', {'contact_id': bola, 'raw': '0803 111 1111', 'normalized': '+2348031111111', 'is_default': 1});
    await db.insert('contact_phones', {'contact_id': bola, 'raw': '0805 222 2222', 'normalized': '+2348052222222'});
    await db.insert('contact_phones', {'contact_id': bola, 'raw': '1234', 'normalized': null});
    await db.insert('contacts', {
      'name': 'From a file', 'phone_raw': '+2348039999999', 'phone_normalized': '+2348039999999',
      'created_at': now, 'updated_at': now,
    });

    final cards = await phonebookCards(db);

    expect(cards, hasLength(1));
    expect(cards.single.key, 'contact:42');
    expect(cards.single.nativeId, 42);
    expect(cards.single.numbers, ['+2348031111111', '+2348052222222']);
    expect(cards.single.chatNumbers, isEmpty, reason: 'not signed in to Contacts++');
    await db.close();
  });
}
