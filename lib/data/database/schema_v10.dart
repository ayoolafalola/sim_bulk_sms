/// Schema v10: Contacts++ backup and sync. Each synced local row gets a
/// stable key shared by all the member's devices and the web app, and the
/// hash of what was last sent, so only changes are uploaded.
const schemaV10 = <String>[
  '''CREATE TABLE sync_links(
    kind TEXT NOT NULL,
    local_id INTEGER NOT NULL,
    sync_key TEXT NOT NULL,
    hash TEXT,
    seq INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(kind, local_id))''',
  'CREATE UNIQUE INDEX idx_sync_links_key ON sync_links(kind, sync_key)',
  // Texts queued on the web, sent from this phone: which campaign row each
  // one became, and the last status reported back to Contacts++.
  '''CREATE TABLE relay_links(
    job_id TEXT PRIMARY KEY,
    campaign_recipient_id INTEGER REFERENCES campaign_recipients(id) ON DELETE SET NULL,
    reported TEXT NOT NULL DEFAULT 'claimed',
    created_at TEXT NOT NULL)''',
  'CREATE INDEX idx_relay_links_recipient ON relay_links(campaign_recipient_id)',
];
