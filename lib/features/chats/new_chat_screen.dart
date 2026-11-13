import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/settings_providers.dart';
import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';

/// Someone you could chat with: a name, their E.164 number, and their
/// Contacts++ member when they are on it.
class _Person {
  const _Person(this.name, this.e164, this.target);
  final String name, e164;
  final ChatTarget? target;
}

/// People from your contacts (this app's and the phone's), split into those
/// on Contacts++ and the rest. Answers are cached by the service for hours.
final _peopleProvider = FutureProvider.autoDispose<List<_Person>>((ref) async {
  final normalizer = ref.watch(phoneNormalizerProvider);
  final byNumber = <String, String>{};
  for (final c in await ref.watch(contactsProvider.future)) {
    final e164 = c.phoneNormalized;
    if (e164 != null && e164.startsWith('+')) byNumber.putIfAbsent(e164, () => c.name);
  }
  try {
    final phone = ref.read(phoneContactsServiceProvider);
    if (await phone.hasPermission()) {
      for (final p in await phone.load()) {
        final e164 = normalizer.normalize(p.phone).e164;
        if (e164 != null) byNumber.putIfAbsent(e164, () => p.name);
      }
    }
  } catch (_) {/* not available here */}
  final reach = await ref.watch(contactsChatServiceProvider).reachability(byNumber.keys);
  final people = [for (final e in byNumber.entries) _Person(e.value, e.key, reach[e.key])]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return people;
});

/// New chat (iPhone, and Android while another app handles texts): pick a
/// Contacts++ member from your contacts, or type a number.
class NewChatScreen extends ConsumerStatefulWidget {
  const NewChatScreen({super.key});

  @override
  ConsumerState<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends ConsumerState<NewChatScreen> {
  String _query = '';

  void _open(String phone, String? name) =>
      context.pushReplacement(Uri(path: '/messages/chat-to', queryParameters: {'to': phone, if (name != null) 'name': name}).toString());

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(_peopleProvider);
    final c = AppColors.of(context);
    final q = _query.toLowerCase();
    final digits = _query.replaceAll(RegExp(r'[^\d+]'), '');
    final typed = digits.length >= 7 ? ref.watch(phoneNormalizerProvider).normalize(_query).e164 : null;
    bool matches(_Person p) =>
        q.isEmpty || p.name.toLowerCase().contains(q) || (digits.length > 2 && p.e164.contains(digits.replaceAll('+', '')));
    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name or phone number'),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        if (typed != null)
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.dialpad)),
            title: Text('Chat with $typed'),
            subtitle: const Text('A chat if they’re on Contacts++'),
            onTap: () => _open(typed, null),
          ),
        Expanded(
          child: people.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const EmptyState(
                icon: Icons.cloud_off_outlined, title: 'Couldn’t check who’s on Contacts++', text: 'Check your connection and try again.'),
            data: (all) {
              final on = all.where((p) => p.target != null && matches(p)).toList();
              final off = all.where((p) => p.target == null && matches(p)).toList();
              if (on.isEmpty && off.isEmpty) {
                return const EmptyState(
                  icon: Icons.person_search_outlined,
                  title: 'No one found',
                  text: 'Type their phone number, or add them to your contacts first.',
                );
              }
              return ListView(padding: pagePadding(context, extra: 24).copyWith(left: 0, right: 0, top: 0), children: [
                if (on.isNotEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SectionLabel('On Contacts++')),
                for (final p in on)
                  ListTile(
                    leading: InitialsAvatar(p.target!.displayName ?? p.name),
                    title: Text(p.name),
                    subtitle: Text(p.e164),
                    trailing: Icon(Icons.forum_outlined, color: Theme.of(context).colorScheme.tertiary),
                    onTap: () => _open(p.e164, p.name),
                  ),
                if (off.isNotEmpty)
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SectionLabel('Not on Contacts++ yet')),
                for (final p in off.take(200))
                  ListTile(
                    leading: InitialsAvatar(p.name),
                    title: Text(p.name),
                    subtitle: Text('${p.e164} · gets a text', style: TextStyle(color: c.muted)),
                    onTap: () => _open(p.e164, p.name),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}
