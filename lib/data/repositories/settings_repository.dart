import 'package:sqflite/sqflite.dart';
import '../../domain/models/birthday_settings.dart';
import '../../domain/models/email_settings.dart';
import '../../domain/models/pro.dart';
import '../../domain/models/send_settings.dart';

/// Key/value app settings in the database, so the background service sees the
/// same values as the app screen.
class SettingsRepository {
  SettingsRepository(this._db);
  final Database _db;

  Future<SendSettings> load() async {
    final rows = await _db.query('app_settings');
    final m = {for (final r in rows) r['key'] as String: r['value'] as String};
    int i(String k, int d) => int.tryParse(m[k] ?? '') ?? d;
    return SendSettings(
      delaySeconds: i('delay_seconds', SendSettings.defaultDelaySeconds)
          .clamp(SendSettings.minDelay, SendSettings.maxDelay),
      hourlyLimit: i('hourly_limit', SendSettings.defaultHourlyLimit).clamp(0, 100000),
      dailyLimit: i('daily_limit', SendSettings.defaultDailyLimit).clamp(0, 100000),
      defaultRegion: m['default_region'] ?? SendSettings.defaultRegionCode,
    );
  }

  Future<void> save(SendSettings s) => _db.transaction((txn) async {
        final b = txn.batch();
        for (final e in {
          'delay_seconds': '${s.delaySeconds}',
          'hourly_limit': '${s.hourlyLimit}',
          'daily_limit': '${s.dailyLimit}',
          'default_region': s.defaultRegion,
        }.entries) {
          b.insert('app_settings', {'key': e.key, 'value': e.value}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await b.commit(noResult: true);
      });

  /// Simple yes/no flags, e.g. 'onboarding_done'.
  Future<bool> flag(String key) async =>
      (await _db.query('app_settings', where: 'key = ?', whereArgs: [key])).firstOrNull?['value'] == '1';

  Future<void> setFlag(String key, bool on) => _db.insert('app_settings', {'key': key, 'value': on ? '1' : '0'},
      conflictAlgorithm: ConflictAlgorithm.replace);

  /// The SIM chosen for a conversation (dual-SIM phones), or null.
  Future<int?> simForThread(int threadId) async => int.tryParse(
      (await _db.query('app_settings', where: 'key = ?', whereArgs: ['sim_thread_$threadId'])).firstOrNull?['value']
              as String? ?? '');

  Future<void> setSimForThread(int threadId, int subId) => _db.insert(
      'app_settings', {'key': 'sim_thread_$threadId', 'value': '$subId'}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<String?> _get(String key) async =>
      (await _db.query('app_settings', where: 'key = ?', whereArgs: [key])).firstOrNull?['value'] as String?;
  Future<void> _set(String key, String value) =>
      _db.insert('app_settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Phone-contacts sync: true (on), false (declined / turned off), null (not asked yet).
  Future<bool?> contactsSync() async => switch (await _get('contacts_sync')) { 'on' => true, 'off' => false, _ => null };
  Future<void> setContactsSync(bool on) => _set('contacts_sync', on ? 'on' : 'off');

  /// Phone clock (ms) of the last contacts sync; 0 = never (next sync reads everything).
  Future<int> contactsSyncedAt() async => int.tryParse(await _get('contacts_sync_at') ?? '') ?? 0;
  Future<void> setContactsSyncedAt(int ms) => _set('contacts_sync_at', '$ms');

  Future<EmailSettings> loadEmail() async => EmailSettings.fromJson(await _get('email_settings'));
  Future<void> saveEmail(EmailSettings s) => _set('email_settings', s.toJson());

  Future<ProStatus> loadPro() async => ProStatus.fromJson(await _get('pro_status'));
  Future<void> savePro(ProStatus s) => _set('pro_status', s.toJson());

  /// Pro only: the user's campaign signature ('' = none).
  Future<String> customSignature() async => await _get('custom_signature') ?? '';
  Future<void> setCustomSignature(String s) => _set('custom_signature', s.trim());

  /// The signature campaign texts and emails get right now (null = none).
  Future<String?> signature() async => campaignSignature(await loadPro(), custom: await customSignature());

  Future<BirthdaySettings> loadBirthdays() async => BirthdaySettings.fromJson(await _get('birthday_wishes'));
  Future<void> saveBirthdays(BirthdaySettings s) => _set('birthday_wishes', s.toJson());
}
