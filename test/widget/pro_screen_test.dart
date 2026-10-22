import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/app/app.dart';
import 'package:sim_bulk_sms/app/capability_providers.dart';
import 'package:sim_bulk_sms/app/providers.dart';
import 'package:sim_bulk_sms/app/router.dart';
import 'package:sim_bulk_sms/app/sending_providers.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/features/pro/pro_controller.dart';
import 'package:sim_bulk_sms/platform/billing/billing_service.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fakes.dart';

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);

/// A store where buying works at once.
class FakeBilling implements BillingService {
  bool subscribed = false;
  final bought = <String>[];
  final _events = StreamController<BillingEvent>.broadcast();
  @override Future<bool> available() async => true;
  @override
  Future<List<ProPlan>> plans() async => const [
        ProPlan(productId: 'comeriver_pro', period: 'monthly', price: '₦2,500', title: 'Pro'),
        ProPlan(productId: 'comeriver_pro', period: 'yearly', price: '₦25,000', title: 'Pro'),
      ];
  @override
  Future<void> buy(ProPlan plan) async {
    bought.add(plan.period);
    subscribed = true;
    _events.add(BillingEvent(BillingEventKind.purchased, productId: plan.productId));
  }
  @override Future<void> restore() async {}
  @override Future<StoreSubscription?> current() async => StoreSubscription(active: subscribed, productId: 'comeriver_pro');
  @override Stream<BillingEvent> get events => _events.stream;
  @override Uri manageUrl() => Uri.parse('https://play.google.com/store/account/subscriptions');
}

void main() {
  sqfliteFfiInit();

  testWidgets('free → buy yearly → Pro, and the signature can be changed', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    late Database db;
    await t.runAsync(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      await SettingsRepository(db).setFlag('onboarding_done', true);
      await SettingsRepository(db).setContactsSync(false);
    });
    addTearDown(() => t.runAsync(db.close));
    final billing = FakeBilling();
    await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        capabilitiesProvider.overrideWith((ref) async => androidOk),
        backgroundSendServiceProvider.overrideWithValue(null),
        smsServiceProvider.overrideWithValue(FakeSmsService(androidOk)),
        billingServiceProvider.overrideWithValue(billing),
      ],
      child: const SimBulkSmsApp(),
    ));
    Future<void> settle({Finder? until}) async {
      for (var i = 0; i < 40; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await t.pump(const Duration(milliseconds: 200));
        if (i >= 3 && (until == null || until.evaluate().isNotEmpty)) return;
      }
    }

    appRouter.go('/settings');
    await settle(until: find.text('Free'));
    await t.tap(find.text('Comeriver Pro'));
    await settle(until: find.text('Yearly · ₦25,000'));
    expect(find.textContaining('free app'), findsOneWidget);
    expect(find.text('Up to 5'), findsOneWidget);

    await t.tap(find.text('Yearly · ₦25,000'));
    await settle(until: find.text('Welcome to Comeriver Pro!'));
    expect(billing.bought, ['yearly']);
    expect(find.textContaining('Pro is on'), findsOneWidget);
    expect((await t.runAsync(() => SettingsRepository(db).loadPro()))!.isPro(), true);

    // Pro: signature off by default; add one.
    expect(await t.runAsync(() => SettingsRepository(db).signature()), isNull);
    await t.ensureVisible(find.text('Add a signature'));
    await t.tap(find.text('Add a signature'));
    await settle(until: find.widgetWithText(TextField, 'Signature'));
    await t.enterText(find.widgetWithText(TextField, 'Signature'), 'Grace Church');
    await settle();
    expect(await t.runAsync(() => SettingsRepository(db).signature()), 'Grace Church');
  });
}
