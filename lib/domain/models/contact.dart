import 'statuses.dart';

class Contact {
  const Contact({
    this.id, required this.name, required this.phoneRaw, this.phoneNormalized,
    this.email, this.consent = ConsentStatus.unknown,
  });
  final int? id;
  final String name;
  final String phoneRaw;
  final String? phoneNormalized; // E.164 when parseable
  final String? email;
  final ConsentStatus consent;
}

class DuplicateContactException implements Exception {
  DuplicateContactException(this.phoneNormalized);
  final String phoneNormalized;
  @override
  String toString() => 'A contact with this phone number already exists.';
}
