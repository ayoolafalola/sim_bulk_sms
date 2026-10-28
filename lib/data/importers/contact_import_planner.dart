import '../../core/phone_numbers/phone_normalizer.dart';
import '../../domain/models/channels.dart';
import '../../domain/services/birthdays.dart';

enum ImportRowStatus { valid, invalidPhone, missingName, duplicateInFile, duplicateExisting }

/// The first number in a cell that may hold several ("0803…, 0805…" or "0803… / 0805…").
({String number, bool more}) firstNumber(String cell) {
  final parts = cell.split(RegExp(r'[,;/|\n]')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  return (number: parts.isEmpty ? '' : parts.first, more: parts.length > 1);
}

String _normHeader(String h) => h.trim().toLowerCase().replaceAll(RegExp(r'[_\-.:#()]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Which file column holds what. The name is one column, or first + last
/// name columns joined with a space ("Ada" + "Lovelace"). A file needs a phone
/// column, an email column, or both (rows with only an email become email-only contacts).
class ColumnMapping {
  const ColumnMapping({this.name, this.firstName, this.lastName, this.phone, this.email, this.birthday});
  final int? name;
  final int? firstName, lastName;
  final int? phone;
  final int? email;
  final int? birthday;

  bool get hasName => name != null || firstName != null || lastName != null;
  /// Something to reach people with.
  bool get hasContactColumn => phone != null || email != null;

  ColumnMapping copyWith({
    int? Function()? name, int? Function()? firstName, int? Function()? lastName, int? Function()? phone,
    int? Function()? email, int? Function()? birthday,
  }) =>
      ColumnMapping(
        name: name == null ? this.name : name(),
        firstName: firstName == null ? this.firstName : firstName(),
        lastName: lastName == null ? this.lastName : lastName(),
        phone: phone == null ? this.phone : phone(),
        email: email == null ? this.email : email(),
        birthday: birthday == null ? this.birthday : birthday(),
      );

  static const _nameAliases = {
    'name', 'full name', 'fullname', 'contact', 'contact name', 'names', 'display name', 'member', 'member name',
  };
  static const _firstAliases = {'first name', 'firstname', 'given name', 'other names', 'other name', 'forename', 'first'};
  static const _lastAliases = {'last name', 'lastname', 'surname', 'family name', 'last'};
  static const _phoneAliases = {
    'phone', 'phone number', 'mobile', 'mobile number', 'number', 'tel', 'telephone', 'msisdn', 'cell', 'cell phone',
    'gsm', 'gsm number', 'whatsapp', 'whatsapp number', 'phone 1', 'mobile phone', 'contact number',
    'telephone number', 'phone no', 'tel no', 'mobile no', 'phone numbers', 'gsm no', 'gsm nos', 'phone nos',
    'mobile nos', 'cell no', 'cell number', 'whatsapp no', 'telephone no',
  };
  static const _emailAliases = {'email', 'e mail', 'email address', 'mail'};
  static const _birthdayAliases = {
    'birthday', 'birth day', 'date of birth', 'dob', 'd o b', 'birth date', 'birthdate', 'bday', 'birthday date',
  };

  static int? _find(List<String> headers, Set<String> aliases) {
    for (var i = 0; i < headers.length; i++) {
      if (aliases.contains(_normHeader(headers[i]))) return i;
    }
    return null;
  }

  /// Mapping from header names; null if neither a phone nor an email column, or no name column(s),
  /// can be found by name (use [guess] to also look at the contents).
  static ColumnMapping? suggest(List<String> headers) {
    final m = ColumnMapping(
      name: _find(headers, _nameAliases), firstName: _find(headers, _firstAliases),
      lastName: _find(headers, _lastAliases), phone: _find(headers, _phoneAliases), email: _find(headers, _emailAliases),
      birthday: _find(headers, _birthdayAliases),
    );
    return m.hasName && m.hasContactColumn ? m : null;
  }

  /// Whether the first row is a header row: true unless it contains a phone number.
  static bool looksLikeHeader(List<String> firstRow, PhoneNormalizer normalizer) =>
      !firstRow.any((c) => normalizer.normalize(firstNumber(c).number).isValid);

  /// Best mapping from headers (when [hasHeader]) and the cell contents:
  /// the phone column is the one with the most valid numbers, the name the
  /// one that's mostly text, email the one with '@', birthday the one with dates.
  /// Null if no column has mostly phone numbers or email addresses.
  static ColumnMapping? guess(List<List<String>> table, {required bool hasHeader, required PhoneNormalizer normalizer}) {
    if (table.isEmpty) return null;
    final width = table.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final headers = hasHeader ? table.first : const <String>[];
    final data = table.skip(hasHeader ? 1 : 0).take(50).toList();

    int? best(bool Function(String) test, Set<int?> exclude) {
      int? col;
      var bestScore = 0.0;
      for (var c = 0; c < width; c++) {
        if (exclude.contains(c)) continue;
        final cells = [for (final r in data) if (c < r.length && r[c].trim().isNotEmpty) r[c].trim()];
        if (cells.isEmpty) continue;
        final score = cells.where(test).length / cells.length;
        // A column must match at least half its non-empty cells; the first best wins ties.
        if (score >= 0.5 && score > bestScore) {
          bestScore = score;
          col = c;
        }
      }
      return col;
    }

    bool isPhone(String v) => normalizer.normalize(firstNumber(v).number).isValid;
    final phone = (hasHeader ? _find(headers, _phoneAliases) : null) ?? best(isPhone, const {});
    final email = (hasHeader ? _find(headers, _emailAliases) : null) ?? best((v) => v.contains('@'), {phone});
    if (phone == null && email == null) return null;
    bool isDate(String v) => parseBirthday(v) != null && !isPhone(v);
    final birthday = (hasHeader ? _find(headers, _birthdayAliases) : null) ?? best(isDate, {phone, email});
    var name = hasHeader ? _find(headers, _nameAliases) : null;
    final first = hasHeader ? _find(headers, _firstAliases) : null;
    final last = hasHeader ? _find(headers, _lastAliases) : null;
    if (name == null && first == null && last == null) {
      name = best((v) => RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(v) && !v.contains('@') && !isPhone(v) && !isDate(v),
          {phone, email, birthday});
    }
    return ColumnMapping(name: name, firstName: first, lastName: last, phone: phone, email: email, birthday: birthday);
  }
}

class ImportRow {
  const ImportRow({required this.line, required this.name, required this.phoneRaw, this.email,
      this.e164, required this.status, this.regionAssumed = false, this.extraNumbersIgnored = false,
      this.birthday, this.birthdayUnreadable = false});
  final int line; // 1-based CSV line number including header
  final String name, phoneRaw;
  final String? email, e164;
  /// Stored form (`YYYY-MM-DD` / `--MM-DD`), or null.
  final String? birthday;
  /// The birthday cell had something that isn't a date (it's left empty).
  final bool birthdayUnreadable;
  /// No valid number, but a valid email: imported as an email-only contact.
  bool get emailOnly => e164 == null && status == ImportRowStatus.valid;
  final ImportRowStatus status;
  final bool regionAssumed;
  /// The cell had more than one number; only the first was used.
  final bool extraNumbersIgnored;
}

class ImportPlan {
  const ImportPlan(this.rows, this.skippedBlank);
  final List<ImportRow> rows;
  final int skippedBlank;
  List<ImportRow> get importable => rows.where((r) => r.status == ImportRowStatus.valid).toList();
  int get valid => importable.length;
  int get invalid => rows.where((r) => r.status == ImportRowStatus.invalidPhone || r.status == ImportRowStatus.missingName).length;
  int get duplicates => rows.where((r) => r.status == ImportRowStatus.duplicateInFile || r.status == ImportRowStatus.duplicateExisting).length;
  int get regionAssumedCount => importable.where((r) => r.regionAssumed).length;
  /// Rows whose number is already one of your contacts (not imported again,
  /// but can be added to a group).
  List<ImportRow> get existing => rows.where((r) => r.status == ImportRowStatus.duplicateExisting).toList();
  int get missingNames => rows.where((r) => r.status == ImportRowStatus.missingName).length;
  int get invalidPhones => rows.where((r) => r.status == ImportRowStatus.invalidPhone).length;
  int get repeatedInFile => rows.where((r) => r.status == ImportRowStatus.duplicateInFile).length;
  int get multiNumberCount => rows.where((r) => r.extraNumbersIgnored).length;
  int get emailOnlyCount => importable.where((r) => r.emailOnly).length;
  int get birthdaysFound => importable.where((r) => r.birthday != null).length;
  int get birthdaysUnreadable => importable.where((r) => r.birthdayUnreadable).length;
  /// Rows that will not be imported, with their line numbers (for "see skipped rows").
  List<ImportRow> get skipped =>
      rows.where((r) => r.status != ImportRowStatus.valid && r.status != ImportRowStatus.duplicateExisting).toList();
}

/// Pure function: no database writes. The UI previews this; only a confirmed
/// plan is committed (in one transaction) by the repository.
/// [hasHeader]: skip the first row. [useNumberAsName]: rows with a valid number
/// but no name are imported with the number as their name.
/// A row needs a valid number or a valid email; with only an email it becomes an email-only contact.
/// [existingEmails] (lower case) are the emails of contacts already saved. [monthFirst]: read 05/17 as 17 May (US).
ImportPlan planImport({
  required List<List<String>> table,
  required ColumnMapping mapping,
  required PhoneNormalizer normalizer,
  required Set<String> existingNormalized,
  Set<String> existingEmails = const {},
  bool hasHeader = true,
  bool useNumberAsName = false,
  bool monthFirst = false,
}) {
  final seen = <String>{}, seenEmails = <String>{};
  final out = <ImportRow>[];
  var blank = 0;
  String cell(List<String> r, int? i) => (i == null || i >= r.length) ? '' : r[i].trim();

  for (var i = hasHeader ? 1 : 0; i < table.length; i++) {
    final r = table[i];
    var name = mapping.name != null
        ? cell(r, mapping.name)
        : [cell(r, mapping.firstName), cell(r, mapping.lastName)].where((p) => p.isNotEmpty).join(' ');
    final (number: phone, more: more) = firstNumber(cell(r, mapping.phone));
    final email = cell(r, mapping.email);
    if (name.isEmpty && phone.isEmpty && email.isEmpty) { blank++; continue; }
    final line = i + 1;
    final n = phone.isEmpty ? null : normalizer.normalize(phone);
    final numberOk = n?.isValid ?? false;
    final emailOk = isValidEmail(email);
    if (name.isEmpty && useNumberAsName && numberOk) name = phone;
    final bdayRaw = cell(r, mapping.birthday);
    final bday = bdayRaw.isEmpty ? null : parseBirthday(bdayRaw, monthFirst: monthFirst);
    ImportRow mk(ImportRowStatus s, {String? e164, bool assumed = false}) => ImportRow(
        line: line, name: name, phoneRaw: phone, email: email.isEmpty ? null : email,
        e164: e164, status: s, regionAssumed: assumed, extraNumbersIgnored: more,
        birthday: bday, birthdayUnreadable: bdayRaw.isNotEmpty && bday == null);

    if (!numberOk && !emailOk) { out.add(mk(ImportRowStatus.invalidPhone)); continue; }
    if (name.isEmpty) { out.add(mk(ImportRowStatus.missingName, e164: numberOk ? n!.e164 : null)); continue; }
    if (numberOk) {
      if (existingNormalized.contains(n!.e164)) { out.add(mk(ImportRowStatus.duplicateExisting, e164: n.e164)); continue; }
      if (!seen.add(n.e164!)) { out.add(mk(ImportRowStatus.duplicateInFile, e164: n.e164)); continue; }
      out.add(mk(ImportRowStatus.valid, e164: n.e164, assumed: n.regionAssumed));
    } else {
      // Email only: the address identifies them.
      final key = email.toLowerCase();
      if (existingEmails.contains(key)) { out.add(mk(ImportRowStatus.duplicateExisting)); continue; }
      if (!seenEmails.add(key)) { out.add(mk(ImportRowStatus.duplicateInFile)); continue; }
      out.add(mk(ImportRowStatus.valid));
    }
  }
  return ImportPlan(out, blank);
}
