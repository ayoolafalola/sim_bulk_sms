/// Schema v2: campaigns remember their audience and fallbacks, can be re-run
/// (resend / schedule), and can have a schedule. Applied on top of v1.
const schemaV2 = <String>[
  // Which run this campaign was created from (resend or scheduled occurrence).
  'ALTER TABLE campaigns ADD COLUMN source_campaign_id INTEGER REFERENCES campaigns(id) ON DELETE SET NULL',
  'ALTER TABLE campaigns ADD COLUMN schedule_id INTEGER',
  // JSON object of user-chosen fallback values for template variables.
  'ALTER TABLE campaigns ADD COLUMN fallbacks_json TEXT',
  '''CREATE TABLE campaign_audience(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    campaign_id INTEGER NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    group_id INTEGER REFERENCES recipient_groups(id) ON DELETE CASCADE,
    contact_id INTEGER REFERENCES contacts(id) ON DELETE CASCADE,
    CHECK((group_id IS NULL) != (contact_id IS NULL)))''',
  'CREATE UNIQUE INDEX idx_audience_group ON campaign_audience(campaign_id, group_id) WHERE group_id IS NOT NULL',
  'CREATE UNIQUE INDEX idx_audience_contact ON campaign_audience(campaign_id, contact_id) WHERE contact_id IS NOT NULL',
  '''CREATE TABLE campaign_schedules(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    campaign_id INTEGER NOT NULL UNIQUE REFERENCES campaigns(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN('once','weekly')),
    run_at TEXT,                  -- once: local date-time (ISO, no zone)
    weekdays INTEGER NOT NULL DEFAULT 0, -- weekly: bit (1 << (weekday-1)), Monday = bit 0
    minute_of_day INTEGER,        -- weekly: local time, minutes after midnight
    ends_on TEXT,                 -- weekly: last local date (inclusive), optional
    enabled INTEGER NOT NULL DEFAULT 1,
    next_run_at TEXT,             -- UTC ISO; null when nothing is left to run
    last_run_at TEXT, last_run_campaign_id INTEGER, last_outcome TEXT,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
  'CREATE INDEX idx_schedules_due ON campaign_schedules(enabled, next_run_at)',
];
