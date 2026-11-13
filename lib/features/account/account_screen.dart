import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../../platform/contacts_plus/contacts_plus_auth.dart';
import '../../platform/contacts_plus/contacts_plus_config.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import 'account_controller.dart';

/// Settings › Contacts++ account: sign in, see who is signed in, sign out.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts++ account')),
      body: account.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const _SignedOut(),
        data: (value) => value == null ? const _SignedOut() : _SignedIn(account: value),
      ),
    );
  }
}

/// What signing in adds. Messages++ keeps working without it.
class _SignedOut extends ConsumerStatefulWidget {
  const _SignedOut();

  @override
  ConsumerState<_SignedOut> createState() => _SignedOutState();
}

class _SignedOutState extends ConsumerState<_SignedOut> {
  bool _opening = false;

  Future<void> _signIn() async {
    setState(() => _opening = true);
    try {
      await ref.read(accountProvider.notifier).signIn();
    } on ContactsPlusException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListView(padding: pagePadding(context, extra: 24), children: [
      const SizedBox(height: 8),
      Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(color: c.successBg, borderRadius: BorderRadius.circular(24)),
          child: Icon(Icons.forum_outlined, size: 34, color: c.successFg),
        ),
      ),
      const SizedBox(height: 16),
      Text('Sign in with Contacts++',
          textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text('Optional. Everything you do now keeps working without an account.',
          textAlign: TextAlign.center, style: TextStyle(color: c.muted)),
      const SizedBox(height: 20),
      const Card(
        margin: EdgeInsets.zero,
        child: Column(children: [
          _Benefit(Icons.bolt_outlined, 'Chat with Contacts++ members',
              'People on Contacts++ get your message as a chat, on every device they use. Everyone else gets a text.'),
          Divider(height: 1),
          _Benefit(Icons.cloud_done_outlined, 'Back up your messages',
              'Keep campaigns, groups and messages safe and bring them to a new phone.'),
          Divider(height: 1),
          _Benefit(Icons.laptop_outlined, 'Write on the web, send from your phone',
              'Compose at messages.comeriver.com; this phone sends the texts.'),
          Divider(height: 1),
          _Benefit(Icons.group_add_outlined, 'Invite people to Contacts++ and Events++',
              'Send invitations to a whole group with your own link.'),
        ]),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _opening ? null : _signIn,
        icon: _opening
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.login),
        label: Text(_opening ? 'Opening Contacts++…' : 'Continue with Contacts++'),
      ),
      const SizedBox(height: 10),
      Text(
        'Contacts++ opens to approve Messages++ and sends you back here. Your Contacts++ password and phonebook are never shared. No Contacts++ yet? You can create a free account with your phone number.',
        textAlign: TextAlign.center,
        style: TextStyle(color: c.muted, fontSize: 12.5, height: 1.4),
      ),
    ]);
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit(this.icon, this.title, this.text);
  final IconData icon;
  final String title, text;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(text),
      );
}

class _SignedIn extends ConsumerWidget {
  const _SignedIn({required this.account});
  final ContactsPlusAccount account;

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out of Contacts++?'),
        content: const Text(
            'Messages++ stops sending Contacts++ chats and backing up from this phone. Your texts, contacts and campaigns stay here.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(accountProvider.notifier).signOut();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Couldn’t sign out. Try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AppColors.of(context);
    return ListView(padding: pagePadding(context, extra: 24), children: [
      Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: switch (ref.watch(profilePhotoProvider).valueOrNull) {
            final photo? => CircleAvatar(radius: 26, backgroundImage: MemoryImage(photo)),
            null => InitialsAvatar(account.displayName, size: 52),
          },
          title: Text(account.displayName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          subtitle: Text(account.username == null ? 'Contacts++ account' : '@${account.username}'),
          trailing: const StatusTag('Connected', tone: Tone.success),
        ),
      ),
      const SectionLabel('Your account'),
      Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          ListTile(
            leading: const Icon(Icons.manage_accounts_outlined),
            title: const Text('Manage in Contacts++'),
            subtitle: const Text('Profile, privacy and devices'),
            trailing: Icon(Icons.open_in_new, color: c.muted),
            onTap: () => launchUrl(Uri.parse('${ContactsPlusConfig.contactsWeb}/profile/edit'),
                mode: LaunchMode.externalApplication),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.laptop_outlined),
            title: const Text('Messages++ on the web'),
            subtitle: const Text('Write on a computer; this phone sends'),
            trailing: Icon(Icons.open_in_new, color: c.muted),
            onTap: () => launchUrl(Uri.parse('${ContactsPlusConfig.messagesWeb}/app'),
                mode: LaunchMode.externalApplication),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () => _signOut(context, ref),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text('Delete account', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            subtitle: const Text('Deletes your Contacts++ account and Messages++ backup'),
            trailing: Icon(Icons.open_in_new, color: c.muted),
            onTap: () => launchUrl(Uri.parse('${ContactsPlusConfig.contactsWeb}/delete-account'),
                mode: LaunchMode.externalApplication),
          ),
        ]),
      ),
    ]);
  }
}
