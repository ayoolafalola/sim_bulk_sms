import 'package:phone_numbers_parser/phone_numbers_parser.dart';

enum PhoneParseStatus { valid, invalid, empty }

class NormalizedPhone {
  const NormalizedPhone(this.status, {this.e164, this.regionAssumed = false, this.reason});
  final PhoneParseStatus status;
  final String? e164;
  /// True when the input had no international prefix and the default region
  /// was used to interpret it. The UI must surface this to the user (FR-02).
  final bool regionAssumed;
  final String? reason;
  bool get isValid => status == PhoneParseStatus.valid;
}

class PhoneNormalizer {
  PhoneNormalizer(String defaultRegion)
      : _iso = IsoCode.values.firstWhere(
          (c) => c.name == defaultRegion.toUpperCase(),
          orElse: () => throw ArgumentError('Unknown region: $defaultRegion'),
        );
  final IsoCode _iso;

  NormalizedPhone normalize(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return const NormalizedPhone(PhoneParseStatus.empty, reason: 'empty');
    final hasIntl = t.startsWith('+') || t.startsWith('00');
    final input = t.startsWith('00') ? '+${t.substring(2)}' : t;
    try {
      final p = PhoneNumber.parse(input, callerCountry: _iso);
      if (!p.isValid()) {
        return const NormalizedPhone(PhoneParseStatus.invalid, reason: 'not_a_valid_number');
      }
      return NormalizedPhone(PhoneParseStatus.valid,
          e164: '+${p.countryCode}${p.nsn}', regionAssumed: !hasIntl);
    } catch (_) {
      return const NormalizedPhone(PhoneParseStatus.invalid, reason: 'unparseable');
    }
  }
}
