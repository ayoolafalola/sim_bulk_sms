import 'package:flutter/services.dart';

/// One phone contact's Messages++ actions in the phone's Contacts app.
class PhonebookCard {
  const PhonebookCard({required this.key, required this.name, required this.numbers, this.chatNumbers = const [], this.nativeId});
  final String key, name;
  final List<String> numbers, chatNumbers;
  final int? nativeId;

  Map<String, Object?> toMap() => {
        'key': key, 'display_name': name, 'numbers': numbers, 'chat_numbers': chatNumbers, 'native_id': nativeId,
      };
}

/// Android: "Text" / "Chat" actions on contacts in the Contacts app (opt-in,
/// needs WRITE_CONTACTS) and Direct Share people in the share sheet.
abstract class PhonebookService {
  Future<bool> canWrite();
  Future<bool> requestWrite();
  Future<({int written, int removed})> synchronize(List<PhonebookCard> cards);
  Future<int> removeAll();
  Future<int> publishShareTargets(List<({String name, String phone})> people);
}

class NativePhonebookService implements PhonebookService {
  static const _ch = MethodChannel('app.sim_bulk_sms/phonebook');

  @override
  Future<bool> canWrite() async => await _ch.invokeMethod<bool>('canWrite') ?? false;

  @override
  Future<bool> requestWrite() async => await _ch.invokeMethod<bool>('requestWrite') ?? false;

  @override
  Future<({int written, int removed})> synchronize(List<PhonebookCard> cards) async {
    final r = await _ch.invokeMapMethod<String, dynamic>('synchronize', {'cards': [for (final c in cards) c.toMap()]});
    return (written: (r?['written'] as num?)?.toInt() ?? 0, removed: (r?['removed'] as num?)?.toInt() ?? 0);
  }

  @override
  Future<int> removeAll() async => await _ch.invokeMethod<int>('removeAll') ?? 0;

  @override
  Future<int> publishShareTargets(List<({String name, String phone})> people) async =>
      await _ch.invokeMethod<int>('publishShareTargets', {
        'people': [for (final p in people) {'name': p.name, 'phone': p.phone}],
      }) ??
      0;
}
