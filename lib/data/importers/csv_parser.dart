class CsvFormatException implements Exception {
  CsvFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Small RFC 4180 parser: quotes, escaped quotes, embedded newlines, CRLF/LF,
/// UTF-8 BOM, and comma/semicolon/tab delimiters (spreadsheet exports).
/// Blank lines are dropped. Throws [CsvFormatException] on an unterminated quote.
List<List<String>> parseCsv(String text) {
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final delim = _detectDelimiter(text);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var fieldWasQuoted = false;

  void endField() { row.add(field.toString()); field.clear(); fieldWasQuoted = false; }
  void endRow() {
    endField();
    final blank = row.length == 1 && row[0].trim().isEmpty && !fieldWasQuoted;
    if (!blank) rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') { field.write('"'); i++; }
        else { inQuotes = false; }
      } else { field.write(c); }
    } else if (c == '"' && field.isEmpty) {
      inQuotes = true; fieldWasQuoted = true;
    } else if (c == delim) {
      endField();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else { field.write(c); }
  }
  if (inQuotes) throw CsvFormatException('The file has an unterminated quoted field.');
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

String _detectDelimiter(String text) {
  final firstLine = text.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  final counts = {',': 0, ';': 0, '\t': 0};
  var q = false;
  for (final ch in firstLine.split('')) {
    if (ch == '"') q = !q;
    if (!q && counts.containsKey(ch)) counts[ch] = counts[ch]! + 1;
  }
  final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
  return best.value == 0 ? ',' : best.key;
}
