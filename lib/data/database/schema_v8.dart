/// Schema v8: the exact text each attempt sent (the rendered message plus the
/// campaign signature at that moment).
const schemaV8 = <String>[
  'ALTER TABLE send_attempts ADD COLUMN sent_body TEXT',
];
