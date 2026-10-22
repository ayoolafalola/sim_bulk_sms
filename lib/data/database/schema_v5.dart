/// Schema v5: which text in the phone's message store (Telephony provider row
/// id) each campaign message is, so conversations can label it
/// "Campaign · <name>" and link to the campaign.
const schemaV5 = <String>[
  '''CREATE TABLE stored_messages(
    sms_id INTEGER PRIMARY KEY,
    campaign_recipient_id INTEGER NOT NULL REFERENCES campaign_recipients(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL)''',
];
