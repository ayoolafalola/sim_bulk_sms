import 'statuses.dart';

/// Where a contact comes from: added in the app (or a file), or synced from the phone.
enum ContactSource { app, phone }

/// A person, in the phone's contact format. [phoneRaw]/[phoneNormalized] and
/// [email] are the number and email used for sending; all of them are in
/// [ContactDetails].
class Contact {
  const Contact({
    this.id, required this.name, required this.phoneRaw, this.phoneNormalized,
    this.email, this.consent = ConsentStatus.unknown, this.source = ContactSource.app,
    this.lookupKey, this.phoneContactId, this.givenName, this.familyName, this.organization, this.jobTitle,
    this.birthday, this.address, this.note,
  });
  final int? id;
  final String name;
  /// May be empty for an email-only contact.
  final String phoneRaw;
  final String? phoneNormalized; // E.164 when parseable
  final String? email;
  final ConsentStatus consent;
  final ContactSource source;
  /// Phone contact identity (Android lookup key / iOS identifier) and Android contact id.
  final String? lookupKey;
  final int? phoneContactId;
  final String? givenName, familyName, organization, jobTitle;
  /// yyyy-mm-dd, or --mm-dd when the year isn't known.
  final String? birthday;
  final String? address, note;

  bool get fromPhone => source == ContactSource.phone;
}

/// One number or email, as labelled on the phone ("Mobile", "Work").
class ContactValue {
  const ContactValue({required this.value, this.normalized, this.label, this.isDefault = false});
  final String value;
  final String? normalized;
  final String? label;
  final bool isDefault;
}

/// A date on the contact: birthday, anniversary or other.
class ContactDate {
  const ContactDate({required this.kind, required this.value, this.label});
  final String kind, value;
  final String? label;
}

/// Everything about a contact, for the contact screen.
class ContactDetails {
  const ContactDetails({required this.contact, this.phones = const [], this.emails = const [], this.dates = const [],
      this.preferredPhone, this.preferredEmail});
  final Contact contact;
  final List<ContactValue> phones, emails;
  final List<ContactDate> dates;
  /// What the user chose for sending, if anything (else automatic).
  final String? preferredPhone, preferredEmail;
}

class DuplicateContactException implements Exception {
  DuplicateContactException(this.phoneNormalized);
  final String phoneNormalized;
  @override
  String toString() => 'A contact with this phone number already exists.';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "17 May 1990", or "17 May" without a year. Unknown formats are shown as-is.
String formatContactDate(String v) {
  final m = RegExp(r'^(\d{4}|-)-?(\d{2})-(\d{2})').firstMatch(v);
  if (m == null) return v;
  final month = int.tryParse(m[2]!) ?? 0, day = int.tryParse(m[3]!) ?? 0;
  if (month < 1 || month > 12) return v;
  return m[1] == '-' ? '$day ${_months[month - 1]}' : '$day ${_months[month - 1]} ${m[1]}';
}
