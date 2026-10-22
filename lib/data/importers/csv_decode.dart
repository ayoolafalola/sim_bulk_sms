import 'dart:convert';
import 'dart:typed_data';
import 'csv_parser.dart';

/// Windows-1252 differs from Latin-1 only in 0x80–0x9F (smart quotes, €, dashes…).
const _cp1252High = <int, int>{
  0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
  0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D,
  0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
  0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
};

/// Text of a CSV file: UTF-8 when valid (with or without BOM), otherwise
/// Windows-1252, which is what Excel on Windows saves "CSV" as. Excel
/// workbooks are refused with instructions.
String decodeCsvBytes(Uint8List bytes) {
  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04) {
    throw CsvFormatException('This looks like an Excel workbook, not a CSV file. In Excel choose '
        'File › Save As › "CSV UTF-8", then import that file.');
  }
  if (bytes.length >= 8 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
    throw CsvFormatException('This looks like an old Excel (.xls) file. Save it as "CSV UTF-8" and import that.');
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return String.fromCharCodes([for (final b in bytes) _cp1252High[b] ?? b]);
  }
}
