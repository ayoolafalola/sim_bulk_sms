/// Schema v9: birthday wishes. One row per person per year they were wished, so nobody gets two in a year.
const schemaV9 = <String>[
  '''CREATE TABLE birthday_wishes(
    contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    year INTEGER NOT NULL,
    campaign_id INTEGER REFERENCES campaigns(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(contact_id, year))''',
];
