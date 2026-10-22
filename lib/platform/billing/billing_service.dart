/// One way to pay for Pro, as the store shows it.
class ProPlan {
  const ProPlan({required this.productId, required this.period, required this.price, required this.title, this.raw});
  final String productId;
  /// 'monthly' or 'yearly'.
  final String period;
  /// Formatted by the store in the user's currency, e.g. "₦2,500.00".
  final String price;
  final String title;
  /// The store's own product object (used to buy).
  final Object? raw;
}

enum BillingEventKind { purchased, restored, pending, canceled, error }

class BillingEvent {
  const BillingEvent(this.kind, {this.productId, this.message});
  final BillingEventKind kind;
  final String? productId;
  final String? message;
}

/// What the store says about the Pro subscription right now.
class StoreSubscription {
  const StoreSubscription({required this.active, this.productId, this.expiresAt});
  final bool active;
  final String? productId;
  /// Known on the App Store; Google Play renews in place (null).
  final DateTime? expiresAt;
}

/// Google Play Billing / App Store subscriptions.
abstract class BillingService {
  Future<bool> available();
  Future<List<ProPlan>> plans();
  /// Starts the store's purchase sheet; the outcome arrives on [events].
  Future<void> buy(ProPlan plan);
  /// Asks the store to re-send active purchases (also on [events]).
  Future<void> restore();
  /// The subscription as the store reports it now, or null if the store couldn't be asked.
  Future<StoreSubscription?> current();
  Stream<BillingEvent> get events;
  /// Where the user manages or cancels the subscription.
  Uri manageUrl();
}
