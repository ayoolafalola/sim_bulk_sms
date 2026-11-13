import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../account/account_controller.dart';
import 'relay_runner.dart';

final relayRunnerProvider = Provider((ref) => RelayRunner(
      db: ref.watch(databaseProvider),
      transport: ContactsRelayTransport(ref.watch(contactsPlusAuthProvider)),
      campaigns: ref.watch(campaignRepositoryProvider),
      platform: () => Platform.isIOS ? 'ios' : 'android',
    ));

/// Campaigns made from web texts that wait for the member's taps (iPhone, or
/// Android without direct sending). The Messages tab offers to open them.
final relayWaitingProvider = StateProvider<List<int>>((ref) => const []);

/// Runs the phone relay: claim, send, report.
final relayControllerProvider = Provider((ref) => RelayController(ref));

class RelayController {
  RelayController(this._ref);
  final Ref _ref;
  bool _busy = false;

  Future<void> run() async {
    if (_busy || _ref.read(accountProvider).valueOrNull == null) return;
    _busy = true;
    try {
      final runner = _ref.read(relayRunnerProvider);
      final fresh = await runner.claim();
      if (fresh.isNotEmpty) _ref.read(dataVersionProvider.notifier).state++;
      // Also texts claimed earlier that never started (e.g. the app stopped).
      final ids = {...fresh, ...await runner.unstarted()};
      final waiting = <int>[];
      for (final id in ids) {
        if (!await _sendAutomatically(id)) waiting.add(id);
      }
      if (waiting.isNotEmpty) {
        final shown = _ref.read(relayWaitingProvider);
        _ref.read(relayWaitingProvider.notifier).state = [...shown, ...waiting.where((id) => !shown.contains(id))];
      }
      await runner.reportResults();
    } catch (_) {
      // Tried again on the next push, return to the app or minute.
    } finally {
      _busy = false;
    }
  }

  /// Android with direct sending: the background service sends it (chats
  /// first, then the SIM). Elsewhere: chats and emails go now; texts wait.
  Future<bool> _sendAutomatically(int campaignId) async {
    final bg = _ref.read(backgroundSendServiceProvider);
    final caps = await _ref.read(smsServiceProvider).getCapabilities();
    if (bg != null && caps.canSendDirectly) return bg.startSend(campaignId);
    final orchestrator = _ref.read(sendOrchestratorProvider);
    await orchestrator.runEmails(campaignId); // runs the Contacts++ chats too
    final pending = await _ref.read(campaignRepositoryProvider).pendingByChannel(campaignId);
    return pending.sms == 0;
  }

  Future<void> reportResults() async {
    try {
      await _ref.read(relayRunnerProvider).reportResults();
    } catch (_) {}
  }
}
