import '../../core/phone_numbers/phone_normalizer.dart';

enum ImportRowStatus { valid, invalidPhone, missingName, duplicateInFile, duplicateExisting }

/// The first number in a cell that may hold several ("0803…, 0805…" or "0803… / 0805…").
({String number, bool more}) firstNumber(String cell) {
  final parts = cell.split(RegExp(r'[,;/|\n]')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  return (number: parts.isEmpty ? '' : parts.first, more: parts.length > 1);
}

String _normHeader(String h) => h.trim().toLowerCase().replaceAll(RegExp(r'[_\-.:#()]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Which file column holds what. The name is one column, or first + last
/// name columns joined with a space ("Ada" + "Lovelace").
class ColumnMapping {
  const ColumnMapping({this.name, this.firstName, this.lastName, required this.phone, this.email});
  final int? name;
  final int? firstName, lastName;
  final int phone;
  final int? email;

  bool get hasName => name != null || firstName != null || lastName != null;

  ColumnMapping copyWith({
    int? Function()? name, int? Function()? firstName, int? Function()? lastName, int? phone, int? Function()? email,
  }) =>
      ColumnMapping(
        name: name == null ? this.name : name(),
        firstName: firstName == null ? this.firstName : firstName(),
        lastName: lastName == null ? this.lastName : lastName(),
        phone: phone ?? this.phone,
        email: email == null ? this.email : email(),
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

  static int? _find(List<String> headers, Set<String> aliases) {
    for (var i = 0; i < headers.length; i++) {
      if (aliases.contains(_normHeader(headers[i]))) return i;
    }
    return null;
  }

  /// Mapping from header names; null if no phone column or no name column(s)
  /// can be found by name (use [guess] to also look at the contents).
  static ColumnMapping? suggest(List<String> headers) {
    final p = _find(headers, _phoneAliases);
    if (p == null) return null;
    final m = ColumnMapping(
      name: _find(headers, _nameAliases), firstName: _find(headers, _firstAliases),
      lastName: _find(headers, _lastAliases), phone: p, email: _find(headers, _emailAliases),
    );
    return m.hasName ? m : null;
  }

  /// Whether the first row is a header row: true unless it contains a phone number.
  static bool looksLikeHeader(List<String> firstRow, PhoneNormalizer normalizer) =>
      !firstRow.any((c) => normalizer.normalize(firstNumber(c).number).isValid);

  /// Best mapping from headers (when [hasHeader]) and the cell contents:
  /// the phone column is the one with the most valid numbers, the name the
  /// one that's mostly text, email the one with '@'. Null if no column has
  /// mostly phone numbers.
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
    if (phone == null) return null;
    final email = (hasHeader ? _find(headers, _emailAliases) : null) ?? best((v) => v.contains('@'), {phone});
    var name = hasHeader ? _find(headers, _nameAliases) : null;
    final first = hasHeader ? _find(headers, _firstAliases) : null;
    final last = hasHeader ? _find(headers, _lastAliases) : null;
    if (name == null && first == null && last == null) {
      name = best((v) => RegExp(r'[A-Za-zÀ-ÿ]').hasMatch(v) && !v.contains('@') && !isPhone(v), {phone, email});
    }
    return ColumnMapping(name: name, firstName: first, lastName: last, phone: phone, email: email);
  }
}

class ImportRow {
  const ImportRow({required this.line, required this.name, required this.phoneRaw, this.email,
      this.e164, required this.status, this.regionAssumed = false, this.extraNumbersIgnored = false});
  final int line; // 1-based CSV line number including header
  final String name, phoneRaw;
  final String? email, e164;
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
  /// Rows that will not be imported, with their line numbers (for "see skipped rows").
  List<ImportRow> get skipped =>
      rows.where((r) => r.status != ImportRowStatus.valid && r.status != ImportRowStatus.duplicateExisting).toList();
}

/// Pure function: no database writes. The UI previews this; only a confirmed
/// plan is committed (in one transaction) by the repository.
/// [hasHeader]: skip the first row. [useNumberAsName]: rows with a valid number
/// but no name are imported with the number as their name.
ImportPlan planImport({
  required List<List<String>> table,
  required ColumnMapping mapping,
  required PhoneNormalizer normalizer,
  required Set<String> existingNormalized,
  bool hasHeader = true,
  bool useNumberAsName = false,
}) {
  final seen = <String>{};
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
    if (name.isEmpty && phone.isEmpty) { blank++; continue; }
    final line = i + 1;
    final n = normalizer.normalize(phone);
    if (name.isEmpty && useNumberAsName && n.isValid) name = phone;
    ImportRow mk(ImportRowStatus s, {String? e164, bool assumed = false}) => ImportRow(
        line: line, name: name, phoneRaw: phone, email: email.isEmpty ? null : email,
        e164: e164, status: s, regionAssumed: assumed, extraNumbersIgnored: more);

    if (!n.isValid) { out.add(mk(ImportRowStatus.invalidPhone)); continue; }
    if (name.isEmpty) { out.add(mk(ImportRowStatus.missingName, e164: n.e164)); continue; }
    if (existingNormalized.contains(n.e164)) { out.add(mk(ImportRowStatus.duplicateExisting, e164: n.e164)); continue; }
    if (!seen.add(n.e164!)) { out.add(mk(ImportRowStatus.duplicateInFile, e164: n.e164)); continue; }
    out.add(mk(ImportRowStatus.valid, e164: n.e164, assumed: n.regionAssumed));
  }
  return ImportPlan(out, blank);
}
