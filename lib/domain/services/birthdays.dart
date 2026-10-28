/// Birthdays are stored like the phone's contacts store them: `YYYY-MM-DD`, or `--MM-DD` when the year
/// isn't known.

const _months = {
  'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3, 'apr': 4, 'april': 4, 'may': 5,
  'jun': 6, 'june': 6, 'jul': 7, 'july': 7, 'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9,
  'oct': 10, 'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
};

bool _leap(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

int _daysIn(int month, int? year) => switch (month) {
      2 => year == null || _leap(year) ? 29 : 28,
      4 || 6 || 9 || 11 => 30,
      _ => 31,
    };

/// The stored form, or null if it isn't a real date (31 April, 29 February 2023…).
String? storeBirthday(int? year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > _daysIn(month, year)) return null;
  if (year != null && (year < 1900 || year > 2100)) return null;
  final md = '${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  return year == null ? '--$md' : '$year-$md';
}

/// (year, month, day) of a stored birthday; year is null when unknown. Null if unreadable.
({int? year, int month, int day})? birthdayParts(String? stored) {
  if (stored == null) return null;
  final m = RegExp(r'^(\d{4}|-)-?(\d{2})-(\d{2})').firstMatch(stored.trim());
  if (m == null) return null;
  final month = int.parse(m[2]!), day = int.parse(m[3]!);
  final year = m[1] == '-' ? null : int.parse(m[1]!);
  return storeBirthday(year, month, day) == null ? null : (year: year, month: month, day: day);
}

/// Reads a birthday typed or exported in a common format:
/// `1990-05-17`, `17/05/1990`, `17-05-1990`, `17.05.90`, `17/05`, `17 May 1990`, `17 May`, `May 17, 1990`.
/// Numeric dates are day first unless [monthFirst] (the US). Null if it can't be read as a real date.
String? parseBirthday(String raw, {bool monthFirst = false}) {
  // "17th May" -> "17 May"
  final s = raw.trim().toLowerCase().replaceAllMapped(RegExp(r'(\d)(st|nd|rd|th)\b'), (m) => m[1]!);
  if (s.isEmpty) return null;
  int? year(String? y) {
    if (y == null) return null;
    final v = int.parse(y);
    if (y.length == 2) return v > (DateTime.now().year % 100) ? 1900 + v : 2000 + v;
    return v;
  }

  // 1990-05-17 (also with time after it, as spreadsheets export)
  var m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})').firstMatch(s);
  if (m != null) return storeBirthday(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  // --05-17 (already stored form)
  m = RegExp(r'^--(\d{2})-(\d{2})$').firstMatch(s);
  if (m != null) return storeBirthday(null, int.parse(m[1]!), int.parse(m[2]!));
  // 17/05/1990, 17-05-90, 17.05, 05/17 (US)
  m = RegExp(r'^(\d{1,2})[-/.](\d{1,2})(?:[-/.](\d{2}|\d{4}))?$').firstMatch(s);
  if (m != null) {
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    final (day, month) = monthFirst ? (b, a) : (a, b);
    return storeBirthday(year(m[3]), month, day);
  }
  // 17 May 1990, 17 may, 17-May-1990
  m = RegExp(r'^(\d{1,2})[\s\-/]+([a-z]+)\.?,?(?:[\s\-/]+(\d{2}|\d{4}))?$').firstMatch(s);
  if (m != null && _months[m[2]] != null) return storeBirthday(year(m[3]), _months[m[2]]!, int.parse(m[1]!));
  // May 17, 1990 / May 17
  m = RegExp(r'^([a-z]+)\.?[\s\-/]+(\d{1,2}),?(?:[\s\-/]+(\d{2}|\d{4}))?$').firstMatch(s);
  if (m != null && _months[m[1]] != null) return storeBirthday(year(m[3]), _months[m[1]]!, int.parse(m[2]!));
  return null;
}

/// Whether [stored] is a birthday on [day]. 29 February birthdays fall on 28 February in other years.
bool isBirthdayOn(String? stored, DateTime day) {
  final b = birthdayParts(stored);
  if (b == null) return false;
  if (b.month == 2 && b.day == 29 && !_leap(day.year)) return day.month == 2 && day.day == 28;
  return day.month == b.month && day.day == b.day;
}

/// The next date (on or after [from], a date) that [stored] is celebrated, or null if unreadable.
DateTime? nextBirthday(String? stored, DateTime from) {
  final b = birthdayParts(stored);
  if (b == null) return null;
  final start = DateTime(from.year, from.month, from.day);
  for (var y = start.year; y <= start.year + 1; y++) {
    final day = b.month == 2 && b.day == 29 && !_leap(y) ? 28 : b.day;
    final d = DateTime(y, b.month, day);
    if (!d.isBefore(start)) return d;
  }
  return null;
}

/// Age turned on that birthday, when the year is known.
int? ageOn(String? stored, DateTime day) {
  final b = birthdayParts(stored);
  return b?.year == null ? null : day.year - b!.year!;
}
