/// SQLite schema v1 (spec §7). Open with PRAGMA foreign_keys = ON.
const schemaV1 = <String>[
  '''CREATE TABLE contacts(
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, phone_raw TEXT NOT NULL,
    phone_normalized TEXT, email TEXT,
    consent_status TEXT NOT NULL DEFAULT 'unknown' CHECK(consent_status IN('unknown','opted_in','opted_out')),
    consent_updated_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
  'CREATE UNIQUE INDEX idx_contacts_phone ON contacts(phone_normalized) WHERE phone_normalized IS NOT NULL',
  '''CREATE TABLE recipient_groups(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
  '''CREATE TABLE group_contacts(
    group_id INTEGER NOT NULL REFERENCES recipient_groups(id) ON DELETE CASCADE,
    contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    PRIMARY KEY(group_id, contact_id))''',
  '''CREATE TABLE campaigns(
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, message_template TEXT NOT NULL,
    status TEXT NOT NULL, platform TEXT NOT NULL, subscription_id INTEGER, recipient_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL, started_at TEXT, completed_at TEXT, updated_at TEXT NOT NULL)''',
  '''CREATE TABLE campaign_recipients(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    contact_id INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
    recipient_name_snapshot TEXT NOT NULL, phone_number_snapshot TEXT NOT NULL, rendered_message TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', attempt_count INTEGER NOT NULL DEFAULT 0,
    last_error_code TEXT, last_error_message TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
  'CREATE INDEX idx_cr_campaign ON campaign_recipients(campaign_id, status)',
  '''CREATE TABLE send_attempts(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    campaign_recipient_id INTEGER NOT NULL REFERENCES campaign_recipients(id) ON DELETE CASCADE,
    attempt_number INTEGER NOT NULL, platform TEXT NOT NULL, native_operation_id TEXT,
    status TEXT NOT NULL, error_code TEXT, error_description TEXT, initiated_at TEXT NOT NULL, result_at TEXT,
    UNIQUE(campaign_recipient_id, attempt_number))''',   // idempotency: one row per attempt
  '''CREATE TABLE suppression_list(
    id INTEGER PRIMARY KEY AUTOINCREMENT, phone_number_normalized TEXT NOT NULL UNIQUE,
    reason TEXT, created_at TEXT NOT NULL)''',
];
