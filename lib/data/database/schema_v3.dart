/// Schema v3: app settings (send delay, limits, default country) readable by
/// both the app screen and the background service, and why/until when a
/// campaign is paused (limits pause it and resume it automatically).
const schemaV3 = <String>[
  'CREATE TABLE app_settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  // 'user' (tapped Pause), 'hourly_limit', 'daily_limit'; null when not paused.
  'ALTER TABLE campaigns ADD COLUMN paused_reason TEXT',
  // UTC ISO: when a limit-paused campaign resumes by itself.
  'ALTER TABLE campaigns ADD COLUMN resume_at TEXT',
];
