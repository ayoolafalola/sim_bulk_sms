/// Schema v7: email. A campaign has a channel and a subject; each recipient row
/// is one message on one channel (someone getting a text and an email has two).
const schemaV7 = <String>[
  // 'sms', 'email', 'both', 'sms_else_email'
  "ALTER TABLE campaigns ADD COLUMN channel TEXT NOT NULL DEFAULT 'sms'",
  'ALTER TABLE campaigns ADD COLUMN subject TEXT',
  // 'sms' or 'email'
  "ALTER TABLE campaign_recipients ADD COLUMN channel TEXT NOT NULL DEFAULT 'sms'",
  'ALTER TABLE campaign_recipients ADD COLUMN email_snapshot TEXT',
  'ALTER TABLE campaign_recipients ADD COLUMN rendered_subject TEXT',
];
