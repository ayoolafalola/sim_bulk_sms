import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/app_info.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../settings/send_settings_screen.dart';

/// The Settings tab: how sending works on this phone, sending safety and app setup.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sendSettingsProvider).valueOrNull;
    final setup = ref.watch(setupStatusProvider).valueOrNull;
    final caps = ref.watch(capabilitiesProvider).valueOrNull;
    final c = AppColors.of(context);
    String limit(int v) => v > 0 ? '$v' : 'Off';
    final country = s == null
        ? ''
        : countryOptions.where((o) => o.code == s.defaultRegion).firstOrNull?.label ?? s.defaultRegion;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(padding: pagePadding(context, extra: 24).copyWith(top: 0), children: [
          const TabTitle('Settings'),
          if (caps != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: caps.canSendDirectly ? c.successBg : c.infoBg, borderRadius: BorderRadius.circular(20)),
              child: Row(children: [
                Icon(caps.canSendDirectly ? Icons.check_circle_outline : Icons.info_outline,
                    color: caps.canSendDirectly ? c.successFg : c.infoFg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    caps.canSendDirectly
                        ? 'Texts send automatically through your SIM.'
                        : caps.messageForUser ?? 'Direct sending is not available on this phone.',
                    style: TextStyle(color: caps.canSendDirectly ? c.successFg : c.infoFg, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
          const SectionLabel('Sending safely'),
          _Group(children: [
            _Row('Delay between messages', s == null ? '' : '${s.delaySeconds} s', () => context.push('/settings/send')),
            _Row('Hourly limit', s == null ? '' : limit(s.hourlyLimit), () => context.push('/settings/send')),
            _Row('Daily limit', s == null ? '' : limit(s.dailyLimit), () => context.push('/settings/send')),
          ]),
          const SectionLabel('App'),
          _Group(children: [
            _Row(
              'App setup',
              null,
              () => context.push('/settings/setup'),
              trailing: setup == null
                  ? null
                  : setup.complete
                      ? const StatusTag('All on', tone: Tone.success)
                      : StatusTag('${setup.missingRequired.length} missing', tone: Tone.danger),
            ),
            _Row('Default country', country, () => context.push('/settings/send')),
          ]),
          const SizedBox(height: 24),
          Center(child: Text('$appName · version 1.0.0', style: TextStyle(color: c.muted, fontSize: 12))),
        ]),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            children[i],
          ],
        ]),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.title, this.value, this.onTap, {this.trailing});
  final String title;
  final String? value;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title),
        onTap: onTap,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (trailing != null) trailing!,
          if (value != null) Text(value!, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, color: AppColors.of(context).muted),
        ]),
      );
}
