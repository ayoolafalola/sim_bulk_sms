/// Schema v6: contacts in the phone's own format, kept in sync with the phone.
/// The contacts row keeps the number and email used for sending (denormalized,
/// so campaigns and eligibility work unchanged); every number, email and date
/// lives in the child tables. App-only details (consent, groups, suppression,
/// the chosen number/email) stay on the app row across syncs.
const schemaV6 = <String>[
  // 'app' = added in the app or from a file; 'phone' = synced from the phone's contacts.
  "ALTER TABLE contacts ADD COLUMN source TEXT NOT NULL DEFAULT 'app'",
  'ALTER TABLE contacts ADD COLUMN lookup_key TEXT',
  'ALTER TABLE contacts ADD COLUMN phone_contact_id INTEGER',
  'ALTER TABLE contacts ADD COLUMN given_name TEXT',
  'ALTER TABLE contacts ADD COLUMN family_name TEXT',
  'ALTER TABLE contacts ADD COLUMN organization TEXT',
  'ALTER TABLE contacts ADD COLUMN job_title TEXT',
  'ALTER TABLE contacts ADD COLUMN birthday TEXT', // yyyy-mm-dd, or --mm-dd without a year
  'ALTER TABLE contacts ADD COLUMN address TEXT',
  'ALTER TABLE contacts ADD COLUMN note TEXT',
  // The number / email the user chose for sending (survives syncs); null = automatic.
  'ALTER TABLE contacts ADD COLUMN preferred_phone TEXT',
  'ALTER TABLE contacts ADD COLUMN preferred_email TEXT',
  // Phone contacts can share a number: no longer unique (eligibility sends once per number).
  'DROP INDEX IF EXISTS idx_contacts_phone',
  'CREATE INDEX idx_contacts_phone ON contacts(phone_normalized)',
  // Phone contacts may share a number; contacts added in the app (by hand or file) may not.
  "CREATE UNIQUE INDEX idx_contacts_app_phone ON contacts(phone_normalized) WHERE source = 'app' AND phone_normalized IS NOT NULL",
  'CREATE UNIQUE INDEX idx_contacts_lookup ON contacts(lookup_key) WHERE lookup_key IS NOT NULL',
  '''CREATE TABLE contact_phones(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    raw TEXT NOT NULL, normalized TEXT, label TEXT, is_default INTEGER NOT NULL DEFAULT 0)''',
  'CREATE INDEX idx_contact_phones ON contact_phones(contact_id)',
  'CREATE INDEX idx_contact_phones_number ON contact_phones(normalized)',
  '''CREATE TABLE contact_emails(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    address TEXT NOT NULL, label TEXT, is_default INTEGER NOT NULL DEFAULT 0)''',
  'CREATE INDEX idx_contact_emails ON contact_emails(contact_id)',
  '''CREATE TABLE contact_dates(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    kind TEXT NOT NULL, value TEXT NOT NULL, label TEXT)''',
  'CREATE INDEX idx_contact_dates ON contact_dates(contact_id)',
];
