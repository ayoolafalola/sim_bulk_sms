import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../app/app_info.dart';
import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../domain/models/pro.dart';
import '../../platform/billing/billing_service.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import 'pro_controller.dart';

/// The plans the store offers (empty when there is no store or it isn't set up).
final proPlansProvider = FutureProvider<List<ProPlan>>((ref) async {
  final billing = ref.watch(billingServiceProvider);
  if (billing == null || !await billing.available()) return const [];
  try {
    return await billing.plans();
  } catch (_) {
    return const [];
  }
});

/// Shown when a free-plan limit is reached: says which, and offers Pro.
Future<void> showProRequired(BuildContext context, String message) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.workspace_premium_outlined),
        title: const Text('Comeriver Pro'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Not now')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/settings/pro');
            },
            child: const Text('See Pro'),
          ),
        ],
      ),
    );

/// Settings › Comeriver Pro: what Pro adds, the plans, restore and manage, and (Pro) the signature.
class ProScreen extends ConsumerStatefulWidget {
  const ProScreen({super.key});

  @override
  ConsumerState<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends ConsumerState<ProScreen> {
  StreamSubscription<BillingEvent>? _sub;
  final _signature = TextEditingController();
  bool _busy = false, _signatureLoaded = false, _signatureOn = false;
  Timer? _saveSignature;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(proControllerProvider).events.listen((e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final m = switch (e.kind) {
        BillingEventKind.purchased => 'Welcome to Comeriver Pro!',
        BillingEventKind.restored => 'Your Pro subscription is restored.',
        BillingEventKind.pending => 'Payment pending. Pro starts when it completes.',
        BillingEventKind.canceled => null,
        BillingEventKind.error => 'The purchase didn\'t go through${e.message == null ? '' : ': ${e.message}'}.',
      };
      if (m != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    });
    ref.read(settingsRepositoryProvider).customSignature().then((s) {
      if (!mounted) return;
      _signature.text = s;
      setState(() {
        _signatureOn = s.isNotEmpty;
        _signatureLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _saveSignature?.cancel();
    _signature.dispose();
    super.dispose();
  }

  Future<void> _storeSignature(String s) async {
    await ref.read(settingsRepositoryProvider).setCustomSignature(s);
    ref.read(dataVersionProvider.notifier).state++;
  }

  Future<void> _buy(ProPlan p) async {
    setState(() => _busy = true);
    try {
      await ref.read(billingServiceProvider)!.buy(p);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start the purchase: $e')));
      }
    }
  }

  Future<void> _restore() async {
    final billing = ref.read(billingServiceProvider);
    if (billing == null) return;
    setState(() => _busy = true);
    try {
      await billing.restore();
      final s = await ref.read(proControllerProvider).refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(s.isPro() ? 'Your Pro subscription is active.' : 'No Pro subscription was found for this account.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(proStatusProvider).valueOrNull ?? const ProStatus();
    final pro = status.isPro();
    final plans = ref.watch(proPlansProvider);
    final billing = ref.watch(billingServiceProvider);
    final c = AppColors.of(context);

    Widget row(String what, String free, String withPro) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(flex: 5, child: Text(what)),
            Expanded(flex: 4, child: Text(free, style: TextStyle(color: c.muted))),
            Expanded(flex: 4, child: Text(withPro, style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Comeriver Pro')),
      body: ListView(padding: pagePadding(context, extra: 24), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: pro ? c.successBg : c.infoBg, borderRadius: BorderRadius.circular(20)),
          child: Row(children: [
            Icon(Icons.workspace_premium, color: pro ? c.successFg : c.infoFg),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                pro
                    ? 'Pro is on${status.debugOverride ? ' (debug)' : ''}. Thank you for supporting Messages++.'
                    : 'You\'re on the free app. Pro removes the limits and lets you change the signature.',
                style: TextStyle(color: pro ? c.successFg : c.infoFg, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
        const SectionLabel('What Pro adds'),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              row('', 'Free', 'Pro'),
              const Divider(),
              row('Campaigns', 'Up to ${FreeLimits.campaigns}', 'Unlimited'),
              row('Schedules', '${FreeLimits.schedules}', 'Unlimited'),
              row('Emails a day', '${FreeLimits.emailsPerDay}', 'Your own limit'),
              row('Signature on campaigns', '"$freeSignature"', 'Yours, or none'),
            ]),
          ),
        ),
        if (!pro) ...[
          const SectionLabel('Choose a plan'),
          plans.when(
            loading: () => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
            error: (_, __) => const Text('Plans couldn\'t be loaded.'),
            data: (list) => list.isEmpty
                ? Text(
                    billing == null
                        ? 'Subscriptions are available when $appName is installed from $storeName.'
                        : 'Plans couldn\'t be loaded from the store. Check your connection and try again.',
                    style: TextStyle(color: c.muted))
                : Column(children: [
                    for (final p in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: (p.period == 'yearly' ? FilledButton.new : FilledButton.tonal)(
                            onPressed: _busy ? null : () => _buy(p),
                            child: Text('${p.period == 'yearly' ? 'Yearly' : 'Monthly'} · ${p.price}'),
                          ),
                        ),
                      ),
                    Text('Renews automatically until you cancel in $storeName.',
                        style: TextStyle(color: c.muted, fontSize: 12)),
                  ]),
          ),
        ],
        if (pro && _signatureLoaded) ...[
          const SectionLabel('Campaign signature'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Add a signature'),
            subtitle: const Text('On its own line at the end of every campaign text and email.'),
            value: _signatureOn,
            onChanged: (v) {
              setState(() => _signatureOn = v);
              _storeSignature(v ? _signature.text : '');
            },
          ),
          if (_signatureOn)
            TextField(
              controller: _signature,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Signature', hintText: 'Grace Church, Lagos'),
              onChanged: (v) {
                _saveSignature?.cancel();
                _saveSignature = Timer(const Duration(milliseconds: 500), () => _storeSignature(v));
              },
            ),
        ],
        const SizedBox(height: 16),
        if (billing != null)
          Wrap(spacing: 8, children: [
            TextButton(onPressed: _busy ? null : _restore, child: const Text('Restore purchases')),
            TextButton(
              onPressed: () => launchUrl(billing.manageUrl(), mode: LaunchMode.externalApplication),
              child: const Text('Manage subscription'),
            ),
          ]),
        if (kDebugMode)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pretend Pro (debug builds only)'),
            value: status.debugOverride,
            onChanged: (v) => ref.read(proControllerProvider).setDebugPro(v),
          ),
      ]),
    );
  }
}
