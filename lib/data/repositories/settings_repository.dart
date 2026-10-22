import 'package:sqflite/sqflite.dart';
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
}
