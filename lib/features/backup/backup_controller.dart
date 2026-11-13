import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../account/account_controller.dart';
import 'backup_sync.dart';
import 'campaign_plans.dart';

final backupSyncProvider = Provider((ref) => BackupSync(
      db: ref.watch(databaseProvider),
      transport: ContactsSyncTransport(ref.watch(contactsPlusAuthProvider)),
      messages: ref.watch(messagesServiceProvider),
      plans: CampaignPlans(
        db: ref.watch(databaseProvider),
        campaigns: ref.watch(campaignRepositoryProvider),
        schedules: ref.watch(scheduleRepositoryProvider),
        composer: ref.watch(composerProvider),
        platform: Platform.isIOS ? 'ios' : 'android',
      ),
    ));

/// Settings › Backup: on/off (off until the member turns it on).
final backupEnabledProvider = FutureProvider<bool>((ref) async {
  ref.watch(dataVersionProvider);
  return await ref.watch(settingsRepositoryProvider).flag('cpp_backup_on');
});

/// A backup run in progress, or the last result.
class BackupState {
  const BackupState({this.progress, this.report, this.error, this.lastAt, this.running = false});
  final SyncProgress? progress;
  final SyncReport? report;
  final String? error;
  final DateTime? lastAt;
  final bool running;
}

final backupControllerProvider = NotifierProvider<BackupController, BackupState>(BackupController.new);

class BackupController extends Notifier<BackupState> {
  static const _autoEvery = Duration(hours: 6);

  @override
  BackupState build() {
    ref.read(backupSyncProvider).lastBackupAt().then((at) {
      if (!state.running) state = BackupState(lastAt: at, report: state.report);
    });
    return const BackupState();
  }

  /// Runs a backup now. Safe to call repeatedly: one run at a time.
  Future<void> runNow() async {
    if (state.running) return;
    if (ref.read(accountProvider).valueOrNull == null) return;
    state = BackupState(running: true, lastAt: state.lastAt);
    try {
      final report = await ref.read(backupSyncProvider).run(onProgress: (p) {
        state = BackupState(running: true, progress: p, lastAt: state.lastAt);
      }).timeout(const Duration(minutes: 10));
      state = BackupState(report: report, lastAt: DateTime.now());
      if (report.downloaded > 0) ref.read(dataVersionProvider.notifier).state++;
    } on ContactsPlusException catch (e) {
      state = BackupState(error: e.message, lastAt: state.lastAt);
    } on TimeoutException {
      state = BackupState(error: 'The backup took too long and stopped. It continues where it left off next time.',
          lastAt: state.lastAt);
    } catch (_) {
      state = BackupState(error: 'The backup didn’t finish. Try again.', lastAt: state.lastAt);
    }
  }

  bool _syncing = false;
  DateTime? _lastSync;

  /// Brings web changes (campaigns, contacts, groups) to this phone and tells
  /// the web what happened to its campaigns. Runs whenever signed in, backup
  /// on or off: on start, on return to the app, every few minutes while
  /// open, and when Contacts++ pushes that something changed. A full backup
  /// run does all of this too.
  Future<void> syncWeb({bool force = false}) async {
    if (_syncing || state.running) return;
    if (ref.read(accountProvider).valueOrNull == null) return;
    final last = _lastSync;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 20)) return;
    _syncing = true;
    try {
      final report = await ref.read(backupSyncProvider).run(full: false).timeout(const Duration(minutes: 2));
      _lastSync = DateTime.now();
      if (report.downloaded > 0) ref.read(dataVersionProvider.notifier).state++;
    } catch (_) {
      // Quiet: the next trigger tries again.
    } finally {
      _syncing = false;
    }
  }

  /// On start and on return to the app: back up when on and due.
  Future<void> runIfDue() async {
    if (!await ref.read(settingsRepositoryProvider).flag('cpp_backup_on')) return syncWeb();
    final last = state.lastAt ?? await ref.read(backupSyncProvider).lastBackupAt();
    if (last != null && DateTime.now().difference(last) < _autoEvery) return syncWeb();
    await runNow();
  }

  Future<void> setEnabled(bool on) async {
    await ref.read(settingsRepositoryProvider).setFlag('cpp_backup_on', on);
    ref.read(dataVersionProvider.notifier).state++;
    if (on) unawaited(runNow());
  }

  /// Deletes the backup from Contacts++ (this phone's data stays).
  Future<void> deleteBackup() async {
    final auth = ref.read(contactsPlusAuthProvider);
    final token = await auth.accessToken();
    if (token == null) return;
    await auth.api.delete('/messages-plus/sync', token: token);
    final db = ref.read(databaseProvider);
    await db.delete('sync_links');
    await db.delete('app_settings', where: "key IN ('cpp_sync_cursor', 'cpp_last_backup_at')");
    await setEnabled(false);
    state = const BackupState();
  }
}
