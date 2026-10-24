import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../app/app_info.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../campaigns/campaign_labels.dart';
import '../contacts/contact_sync_runner.dart';
import '../pro/pro_controller.dart';
import 'app_reset.dart';
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
          const SizedBox(height: 12),
          _Group(children: [
            _Row('Comeriver Pro', null, () => context.push('/settings/pro'),
                trailing: (ref.watch(proStatusProvider).valueOrNull?.isPro() ?? false)
                    ? const StatusTag('Pro', tone: Tone.success)
                    : const StatusTag('Free', tone: Tone.info)),
          ]),
          const SectionLabel('Sending safely'),
          _Group(children: [
            _Row('Delay between messages', s == null ? '' : '${s.delaySeconds} s', () => context.push('/settings/send')),
            _Row('Hourly limit', s == null ? '' : limit(s.hourlyLimit), () => context.push('/settings/send')),
            _Row('Daily limit', s == null ? '' : limit(s.dailyLimit), () => context.push('/settings/send')),
          ]),
          const SectionLabel('Email'),
          _Group(children: [
            _Row('Email sending', ref.watch(emailSettingsProvider).valueOrNull?.providerLabel ?? '',
                () => context.push('/settings/email'),
                trailing: ref.watch(emailSettingsProvider).valueOrNull?.ready == false &&
                        ref.watch(emailSettingsProvider).valueOrNull?.provider.name != 'off'
                    ? const StatusTag('Not finished', tone: Tone.warn)
                    : null),
          ]),
          const SectionLabel('Contacts'),
          const _ContactsSyncGroup(),
          const SectionLabel('App'),
          _Group(children: [
            // Android only: the permissions and battery settings background sending needs.
            if (ref.watch(backgroundSendServiceProvider) != null)
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
          const SectionLabel('About'),
          _Group(children: [
            const _Link(Icons.share_outlined, 'Share $appName', _share),
            _Link(Icons.language, 'Website', () => _open(AppLinks.website)),
            _Link(Icons.privacy_tip_outlined, 'Privacy policy', () => _open(AppLinks.privacy)),
            _Link(Icons.description_outlined, 'Terms of use', () => _open(AppLinks.terms)),
            const _Link(Icons.mail_outline, 'Contact support', _emailSupport),
            _Link(Icons.business_outlined, 'Made by Comeriver', () => _open(AppLinks.developer)),
          ]),
          const SizedBox(height: 24),
          Center(child: Text('$appFullName · version $appVersion', style: TextStyle(color: c.muted, fontSize: 12))),
          // Out of the way on purpose: it erases the app's own data.
          Center(
            child: TextButton(
              style: TextButton.styleFrom(foregroundColor: c.muted, textStyle: const TextStyle(fontSize: 12)),
              onPressed: () => _confirmReset(context, ref),
              child: const Text('Reset app…'),
            ),
          ),
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

class _Link extends StatelessWidget {
  const _Link(this.icon, this.title, this.onTap);
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: AppColors.of(context).muted),
        title: Text(title),
        trailing: Icon(Icons.chevron_right, color: AppColors.of(context).muted),
        onTap: onTap,
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

/// Phone-contacts sync: on/off, how many came from the phone, and when it last ran.
class _ContactsSyncGroup extends ConsumerStatefulWidget {
  const _ContactsSyncGroup();

  @override
  ConsumerState<_ContactsSyncGroup> createState() => _ContactsSyncGroupState();
}

class _ContactsSyncGroupState extends ConsumerState<_ContactsSyncGroup> {
  bool _busy = false;

  Future<void> _do(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = ref.watch(contactsSyncModeProvider).valueOrNull == true;
    final info = ref.watch(contactsSyncInfoProvider).valueOrNull;
    final runner = ref.read(contactSyncRunnerProvider);
    final at = info?.at;
    final subtitle = !on
        ? 'Show everyone in your phone\'s Contacts here, kept up to date.'
        : [
            '${info?.count ?? 0} from your phone',
            if (at != null) 'synced ${formatWhen(at)}',
          ].join(' · ');
    return _Group(children: [
      SwitchListTile(
        title: const Text('Sync phone contacts'),
        subtitle: Text(subtitle),
        value: on,
        onChanged: _busy
            ? null
            : (v) => _do(() async {
                  if (!v) return runner.disable();
                  final messenger = ScaffoldMessenger.of(context);
                  if (await runner.enable() == null && !await ref.read(phoneContactsServiceProvider).hasPermission()) {
                    messenger.showSnackBar(
                        const SnackBar(content: Text('Allow Contacts access to use your phone\'s contacts.')));
                  }
                }),
      ),
      if (on)
        ListTile(
          title: const Text('Sync now'),
          trailing: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sync),
          onTap: _busy ? null : () => _do(() => runner.run(full: true)),
        ),
    ]);
  }
}

Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

Future<void> _share() => SharePlus.instance.share(ShareParams(
      subject: appFullName,
      text: 'I use $appName to message my groups by text and email. Get it: ${AppLinks.website}',
    ));

/// Opens the email app to support, with the app version and system filled in.
Future<void> _emailSupport() => launchUrl(Uri(
      scheme: 'mailto',
      path: AppLinks.supportEmail,
      query: _encodeQuery({
        'subject': '$appName support',
        'body': '\n\n---\n$appName $appVersion · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      }),
    ));

// mailto: needs %20 for spaces (Uri.queryParameters would write "+").
String _encodeQuery(Map<String, String> p) =>
    p.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');

/// Asks twice (typing RESET), then empties the app's data and starts over at the welcome screen.
Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
  if (await ref.read(campaignRepositoryProvider).anySending()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A campaign is sending. Pause or cancel it before resetting the app.')));
    }
    return;
  }
  if (!context.mounted) return;
  final typed = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Reset $appName?'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('This erases everything the app keeps and starts it fresh, as if just installed:'),
            const SizedBox(height: 8),
            const Text('• campaigns, their history and schedules\n• groups\n• contacts you added or imported from files\n'
                '• email settings and the Gmail connection\n• your signature and settings'),
            const SizedBox(height: 8),
            const Text('Kept: the texts on your phone, your phone\'s contacts, and your Pro subscription.',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Texts already sent by campaigns stay on the phone but lose their "Campaign" label.'),
            const SizedBox(height: 16),
            TextField(
              controller: typed,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Type RESET to confirm'),
              onChanged: (_) => setState(() {}),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: typed.text.trim().toUpperCase() == 'RESET' ? () => Navigator.pop(ctx, true) : null,
            child: const Text('Reset'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;
  final bg = ref.read(backgroundSendServiceProvider);
  final gmail = ref.read(gmailAuthProvider);
  final db = ref.read(databaseProvider);
  final version = ref.read(dataVersionProvider.notifier);
  final pro = ref.read(proControllerProvider);
  try {
    await gmail.disconnect();
  } catch (_) {/* not connected, or no Google services */}
  try {
    await bg?.scheduleWake(null); // no schedules left to wake up for
  } catch (_) {}
  await resetAppData(db);
  version.state++;
  await pro.refresh(); // Pro comes back from the store
  if (context.mounted) context.go('/welcome');
}
