import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/providers.dart';
import '../../domain/models/pro.dart';
import '../../platform/billing/billing_service.dart';

/// Google Play / App Store billing; null where there is no store (desktop, tests).
final billingServiceProvider = Provider<BillingService?>((ref) => null);

/// Keeps the saved Pro status in step with the store: on app start, on return to the
/// app, and when a purchase comes through. The background sender reads the saved status.
class ProController {
  ProController(this._ref);
  final Ref _ref;
  StreamSubscription<BillingEvent>? _sub;
  final _events = StreamController<BillingEvent>.broadcast();

  /// Purchase outcomes, for the Pro screen's messages.
  Stream<BillingEvent> get events => _events.stream;

  void start() {
    final billing = _ref.read(billingServiceProvider);
    if (billing == null || _sub != null) return;
    _sub = billing.events.listen(_onEvent);
    unawaited(refresh());
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _events.close();
  }

  /// Asks the store and saves what it says. Keeps the last status when it can't be asked.
  Future<ProStatus> refresh() async {
    final settings = _ref.read(settingsRepositoryProvider);
    final old = await settings.loadPro();
    final cur = await _ref.read(billingServiceProvider)?.current();
    if (cur == null) return old;
    final next = ProStatus(
      active: cur.active, verifiedAt: DateTime.now(), expiresAt: cur.expiresAt,
      productId: cur.productId ?? old.productId, debugOverride: old.debugOverride,
    );
    await settings.savePro(next);
    _ref.read(dataVersionProvider.notifier).state++;
    return next;
  }

  Future<void> _onEvent(BillingEvent e) async {
    if (e.kind == BillingEventKind.purchased || e.kind == BillingEventKind.restored) {
      final settings = _ref.read(settingsRepositoryProvider);
      final old = await settings.loadPro();
      await settings.savePro(old.copyWith(active: true, verifiedAt: DateTime.now(), productId: e.productId));
      _ref.read(dataVersionProvider.notifier).state++;
      unawaited(refresh()); // picks up the expiry date where the store has one
    }
    if (!_events.isClosed) _events.add(e);
  }

  /// Debug builds: pretend Pro is on, to try the Pro features without paying.
  Future<void> setDebugPro(bool on) async {
    final settings = _ref.read(settingsRepositoryProvider);
    await settings.savePro((await settings.loadPro()).copyWith(debugOverride: on));
    _ref.read(dataVersionProvider.notifier).state++;
  }
}

final proControllerProvider = Provider((ref) {
  final c = ProController(ref);
  ref.onDispose(c.dispose);
  return c;
});
