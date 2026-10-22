import 'dart:async';
import 'dart:io' show Platform;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import '../../domain/models/pro.dart';
import 'billing_service.dart';

/// [BillingService] with Flutter's official `in_app_purchase` plugin. Purchases are checked
/// on the phone with Google Play / the App Store; there is no server.
class StoreBillingService implements BillingService {
  final _iap = InAppPurchase.instance;
  StreamController<BillingEvent>? _events;

  @override
  Future<bool> available() async {
    try {
      return await _iap.isAvailable();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<ProPlan>> plans() async {
    final res = await _iap.queryProductDetails(ProProducts.all);
    final out = <ProPlan>[];
    for (final p in res.productDetails) {
      if (p is GooglePlayProductDetails) {
        final i = p.subscriptionIndex;
        final offers = p.productDetails.subscriptionOfferDetails;
        if (i == null || offers == null) continue;
        final offer = offers[i];
        if (offer.offerId != null) continue; // promotions: only the base plans are offered
        final period = offer.pricingPhases.last.billingPeriod; // ISO 8601, e.g. P1M / P1Y
        out.add(ProPlan(productId: p.id, period: period.endsWith('Y') ? 'yearly' : 'monthly',
            price: p.price, title: p.title, raw: p));
      } else {
        out.add(ProPlan(productId: p.id, period: p.id == ProProducts.appStoreYearly ? 'yearly' : 'monthly',
            price: p.price, title: p.title, raw: p));
      }
    }
    out.sort((a, b) => a.period.compareTo(b.period)); // monthly, yearly
    return out;
  }

  @override
  Future<void> buy(ProPlan plan) async {
    await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: plan.raw! as ProductDetails));
  }

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Stream<BillingEvent> get events {
    final c = _events ??= StreamController<BillingEvent>.broadcast(onListen: () {
      _iap.purchaseStream.listen((purchases) async {
        for (final p in purchases) {
          // Acknowledge/finish every purchase, or the store refunds it after 3 days.
          if (p.pendingCompletePurchase) {
            try {
              await _iap.completePurchase(p);
            } catch (_) {}
          }
          if (!ProProducts.all.contains(p.productID)) continue;
          _events?.add(switch (p.status) {
            PurchaseStatus.purchased => BillingEvent(BillingEventKind.purchased, productId: p.productID),
            PurchaseStatus.restored => BillingEvent(BillingEventKind.restored, productId: p.productID),
            PurchaseStatus.pending => BillingEvent(BillingEventKind.pending, productId: p.productID),
            PurchaseStatus.canceled => const BillingEvent(BillingEventKind.canceled),
            PurchaseStatus.error => BillingEvent(BillingEventKind.error, message: p.error?.message),
          });
        }
      }, onError: (Object e) => _events?.add(BillingEvent(BillingEventKind.error, message: '$e')));
    });
    return c.stream;
  }

  @override
  Future<StoreSubscription?> current() async {
    try {
      if (Platform.isAndroid) {
        final res = await _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>().queryPastPurchases();
        if (res.error != null) return null;
        for (final p in res.pastPurchases) {
          final w = p.billingClientPurchase;
          if (!w.products.any(ProProducts.all.contains) || w.purchaseState != PurchaseStateWrapper.purchased) continue;
          if (!w.isAcknowledged) {
            try {
              await _iap.completePurchase(p);
            } catch (_) {}
          }
          return StoreSubscription(active: true, productId: w.products.first);
        }
        return const StoreSubscription(active: false);
      }
      if (Platform.isIOS) {
        DateTime? best;
        String? product;
        for (final t in await SK2Transaction.transactions()) {
          if (!ProProducts.all.contains(t.productId) || t.expirationDate == null) continue;
          final end = DateTime.tryParse(t.expirationDate!);
          if (end != null && (best == null || end.isAfter(best))) {
            best = end;
            product = t.productId;
          }
        }
        final active = best != null && best.isAfter(DateTime.now());
        return StoreSubscription(active: active, productId: product, expiresAt: best?.toLocal());
      }
    } catch (_) {/* store unavailable: keep the last known status */}
    return null;
  }

  @override
  Uri manageUrl() => Platform.isIOS
      ? Uri.parse('https://apps.apple.com/account/subscriptions')
      : Uri.parse('https://play.google.com/store/account/subscriptions'
          '?sku=${ProProducts.playSubscription}&package=com.comeriver.messages');
}
