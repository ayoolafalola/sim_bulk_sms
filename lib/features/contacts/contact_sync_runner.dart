import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../app/settings_providers.dart';
import '../../data/sync/contact_sync.dart';

/// Phone-contacts sync on/off (null = not asked yet).
final contactsSyncModeProvider = FutureProvider<bool?>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(settingsRepositoryProvider).contactsSync();
});

/// When the last contacts sync ran, and how many contacts came from the phone.
final contactsSyncInfoProvider = FutureProvider<({DateTime? at, int count})>((ref) async {
  ref.watch(dataVersionProvider);
  final at = await ref.watch(settingsRepositoryProvider).contactsSyncedAt();
  final rows = await ref.watch(databaseProvider).rawQuery("SELECT COUNT(*) AS n FROM contacts WHERE source = 'phone'");
  return (at: at == 0 ? null : DateTime.fromMillisecondsSinceEpoch(at), count: rows.first['n'] as int);
});

/// Runs a contacts sync when it's on and allowed: everything the first time,
/// then only what changed. Safe to call often; overlapping calls are skipped.
class ContactSyncRunner {
  ContactSyncRunner(this._ref);
  final Ref _ref;
  bool _running = false;

  Future<ContactSyncResult?> run({bool full = false}) async {
    if (_running) return null;
    final settings = _ref.read(settingsRepositoryProvider);
    if (await settings.contactsSync() != true) return null;
    final phone = _ref.read(phoneContactsServiceProvider);
    try {
      if (!await phone.hasPermission()) return null;
      _running = true;
      final since = full ? 0 : await settings.contactsSyncedAt();
      final snap = await phone.sync(since: since);
      final result = await ContactSync(_ref.read(databaseProvider), _ref.read(phoneNormalizerProvider)).apply(snap);
      await settings.setContactsSyncedAt(snap.now);
      _ref.read(dataVersionProvider.notifier).state++;
      return result;
    } catch (_) {
      return null; // not available on this platform, or the phone refused: try again next time
    } finally {
      _running = false;
    }
  }

  /// "Use phone contacts": asks for access, turns sync on and reads everything.
  Future<ContactSyncResult?> enable() async {
    final phone = _ref.read(phoneContactsServiceProvider);
    if (!await phone.hasPermission() && !await phone.requestPermission()) return null;
    await _ref.read(settingsRepositoryProvider).setContactsSync(true);
    return run(full: true);
  }

  Future<void> disable() async {
    await _ref.read(settingsRepositoryProvider).setContactsSync(false);
    _ref.read(dataVersionProvider.notifier).state++;
  }
}

final contactSyncRunnerProvider = Provider((ref) => ContactSyncRunner(ref));
