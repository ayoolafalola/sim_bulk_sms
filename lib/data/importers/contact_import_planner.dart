import '../../core/phone_numbers/phone_normalizer.dart';

enum ImportRowStatus { valid, invalidPhone, missingName, duplicateInFile, duplicateExisting }

class ColumnMapping {
  const ColumnMapping({required this.name, required this.phone, this.email});
  final int name;
  final int phone;
  final int? email;

  static const _nameAliases = {'name', 'full name', 'fullname', 'contact', 'contact name'};
  static const _phoneAliases = {'phone', 'phone number', 'mobile', 'mobile number', 'number', 'tel', 'telephone', 'msisdn'};
  static const _emailAliases = {'email', 'e-mail', 'email address'};

  /// Suggests a mapping from header names; null if name/phone can't be found
  /// (the UI then asks the user to map columns manually).
  static ColumnMapping? suggest(List<String> headers) {
    int? find(Set<String> a) {
      for (var i = 0; i < headers.length; i++) {
        if (a.contains(headers[i].trim().toLowerCase())) return i;
      }
      return null;
    }
    final n = find(_nameAliases), p = find(_phoneAliases);
    if (n == null || p == null) return null;
    return ColumnMapping(name: n, phone: p, email: find(_emailAliases));
  }
}

class ImportRow {
  const ImportRow({required this.line, required this.name, required this.phoneRaw, this.email,
      this.e164, required this.status, this.regionAssumed = false});
  final int line; // 1-based CSV line number including header
  final String name, phoneRaw;
  final String? email, e164;
  final ImportRowStatus status;
  final bool regionAssumed;
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
}

/// Pure function: no database writes. The UI previews this; only a confirmed
/// plan is committed (in one transaction) by the repository.
ImportPlan planImport({
  required List<List<String>> table, // first row = headers
  required ColumnMapping mapping,
  required PhoneNormalizer normalizer,
  required Set<String> existingNormalized,
}) {
  final seen = <String>{};
  final out = <ImportRow>[];
  var blank = 0;
  String cell(List<String> r, int? i) => (i == null || i >= r.length) ? '' : r[i].trim();

  for (var i = 1; i < table.length; i++) {
    final r = table[i];
    final name = cell(r, mapping.name), phone = cell(r, mapping.phone);
    final email = cell(r, mapping.email);
    if (name.isEmpty && phone.isEmpty) { blank++; continue; }
    final line = i + 1;
    ImportRow mk(ImportRowStatus s, {String? e164, bool assumed = false}) => ImportRow(
        line: line, name: name, phoneRaw: phone, email: email.isEmpty ? null : email,
        e164: e164, status: s, regionAssumed: assumed);

    final n = normalizer.normalize(phone);
    if (!n.isValid) { out.add(mk(ImportRowStatus.invalidPhone)); continue; }
    if (name.isEmpty) { out.add(mk(ImportRowStatus.missingName, e164: n.e164)); continue; }
    if (existingNormalized.contains(n.e164)) { out.add(mk(ImportRowStatus.duplicateExisting, e164: n.e164)); continue; }
    if (!seen.add(n.e164!)) { out.add(mk(ImportRowStatus.duplicateInFile, e164: n.e164)); continue; }
    out.add(mk(ImportRowStatus.valid, e164: n.e164, assumed: n.regionAssumed));
  }
  return ImportPlan(out, blank);
}
