/// Estimates SMS encoding and segment count (FR-06). This is an ESTIMATE, not a
/// carrier quotation; never present it as a guaranteed billing figure.
enum SmsEncoding { gsm7, ucs2 }

class SmsEstimate {
  const SmsEstimate({required this.encoding, required this.units, required this.segments, required this.perSegmentLimit});
  final SmsEncoding encoding;
  /// GSM-7 septets (extension chars count 2) or UTF-16 code units.
  final int units;
  final int segments;
  final int perSegmentLimit;
}

class SmsSegmentEstimator {
  static const _basic =
      '@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u001BÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?'
      '¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
  static const _extension = '\f^{}\\[~]|€';

  static final Set<int> _basicSet = _basic.runes.toSet();
  static final Set<int> _extSet = _extension.runes.toSet();

  /// Whether [rune] fits the GSM-7 alphabet (basic or extension table).
  static bool isGsm(int rune) => rune != 0x1B && (_basicSet.contains(rune) || _extSet.contains(rune));

  /// The distinct characters that force the shorter Unicode (UCS-2) SMS.
  static List<String> nonGsmCharacters(String text) {
    final out = <String>[];
    for (final r in text.runes) {
      if (!isGsm(r)) {
        final c = String.fromCharCode(r);
        if (!out.contains(c)) out.add(c);
      }
    }
    return out;
  }

  /// Look-alike swaps that phone keyboards often insert automatically
  /// (smart quotes, long dashes, ellipsis, non-breaking space).
  static const plainReplacements = {
    '\u2018': "'", '\u2019': "'", '\u201A': "'", '\u2032': "'",
    '\u201C': '"', '\u201D': '"', '\u201E': '"', '\u2033': '"',
    '\u2013': '-', '\u2014': '-', '\u2212': '-',
    '\u2026': '...', '\u00A0': ' ', '\u202F': ' ',
  };

  /// [text] with [plainReplacements] applied (other characters untouched).
  static String toPlainCharacters(String text) {
    final b = StringBuffer();
    for (final r in text.runes) {
      final c = String.fromCharCode(r);
      b.write(plainReplacements[c] ?? c);
    }
    return b.toString();
  }

  static SmsEstimate estimate(String text) {
    var septets = 0;
    var gsm = true;
    for (final r in text.runes) {
      if (r == 0x1B) { gsm = false; break; } // raw ESC is not a user-typeable GSM char
      if (_basicSet.contains(r)) {
        septets += 1;
      } else if (_extSet.contains(r)) {
        septets += 2;
      } else {
        gsm = false;
        break;
      }
    }
    if (gsm) {
      final segs = septets == 0 ? 0 : (septets <= 160 ? 1 : (septets / 153).ceil());
      return SmsEstimate(encoding: SmsEncoding.gsm7, units: septets, segments: segs,
          perSegmentLimit: segs <= 1 ? 160 : 153);
    }
    final units = text.length; // Dart String length == UTF-16 code units (emoji = 2)
    final segs = units == 0 ? 0 : (units <= 70 ? 1 : (units / 67).ceil());
    return SmsEstimate(encoding: SmsEncoding.ucs2, units: units, segments: segs,
        perSegmentLimit: segs <= 1 ? 70 : 67);
  }
}
