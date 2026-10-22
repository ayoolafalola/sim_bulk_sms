import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../app/settings_providers.dart';
import '../../app/theme.dart';
import '../../platform/contacts/phone_contacts_service.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import '../contacts/import_phone_contacts_screen.dart' show filterPhoneContacts;

/// Someone to text: a display name and the number to send to.
class Recipient {
  const Recipient(this.name, this.address);
  final String name, address;
}

/// New message: choose people from your app contacts, your phone's contacts or
/// a typed number, write once, and each gets their own text.
class NewMessageScreen extends ConsumerStatefulWidget {
  const NewMessageScreen({super.key});

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  final _to = TextEditingController();
  final _body = TextEditingController();
  final _picked = <Recipient>[];
  List<PhoneContact> _phone = const [];
  bool _phoneAllowed = false, _sending = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadPhone(ask: false);
  }

  @override
  void dispose() {
    _to.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _loadPhone({required bool ask}) async {
    final svc = ref.read(phoneContactsServiceProvider);
    try {
      var ok = await svc.hasPermission();
      if (!ok && ask) ok = await svc.requestPermission();
      if (!ok) return;
      final all = await svc.load();
      if (mounted) setState(() { _phone = all; _phoneAllowed = true; });
    } catch (_) {/* not available on this platform */}
  }

  void _add(Recipient r) {
    if (_picked.any((p) => p.address == r.address)) return;
    setState(() {
      _picked.add(r);
      _to.clear();
      _query = '';
    });
  }

  Future<void> _send() async {
    final body = _body.text.trim();
    if (body.isEmpty || _picked.isEmpty || _sending) return;
    final svc = ref.read(messagesServiceProvider);
    final isDefault = await svc?.isDefault() ?? false;
    if (!mounted) return;
    if (!isDefault) {
      // Not the default messaging app: hand the first one to the Messages app.
      await ref.read(messagesAppProvider)?.open(_picked.first.address, body);
      return;
    }
    setState(() => _sending = true);
    var ok = 0;
    for (final r in _picked) {
      if (await svc!.send(r.address, body)) ok++;
    }
    ref.read(messagesVersionProvider.notifier).state++;
    if (!mounted) return;
    if (_picked.length == 1 && ok == 1) {
      final thread = await svc!.threadIdFor(_picked.first.address);
      if (mounted) context.pushReplacement('/messages/thread/$thread');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok == _picked.length ? 'Sent to $ok people.' : 'Sent to $ok of ${_picked.length}. Check your signal.')));
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final normalizer = ref.watch(phoneNormalizerProvider);
    final appContacts = ref.watch(allContactsProvider).valueOrNull ?? const [];
    final isDefault = ref.watch(isDefaultSmsProvider).valueOrNull ?? false;
    final q = _query.trim().toLowerCase();
    final typed = q.isEmpty ? null : normalizer.normalize(_query);
    final suggestions = <Recipient>[
      if (typed != null && typed.isValid) Recipient(_query.trim(), typed.e164!),
      if (q.isNotEmpty) ...[
        for (final c in appContacts)
          if ((c.name.toLowerCase().contains(q) || c.phoneRaw.contains(q) || (c.phoneNormalized?.contains(q) ?? false)) &&
              c.phoneNormalized != null)
            Recipient(c.name, c.phoneNormalized!),
        for (final i in filterPhoneContacts(_phone, _query).take(30)) Recipient(_phone[i].name, _phone[i].phone),
      ],
    ];
    final seen = <String>{};
    final unique = [
      for (final s in suggestions)
        if (seen.add(normalizer.normalize(s.address).e164 ?? s.address)) s,
    ];
    final c = AppColors.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('New message')),
      body: FormPage(
        action: Row(children: [
          Expanded(
            child: TextField(
              controller: _body,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Text message'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Send',
            style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
            onPressed: _picked.isEmpty || _body.text.trim().isEmpty || _sending ? null : _send,
            icon: const Icon(Icons.send),
          ),
        ]),
        children: [
          if (_picked.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in _picked)
                InputChip(
                  label: Text(r.name == r.address ? r.address : r.name),
                  onDeleted: () => setState(() => _picked.remove(r)),
                ),
            ]),
          const SizedBox(height: 8),
          TextField(
            controller: _to,
            autofocus: true,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.person_search), hintText: 'Name or number'),
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: (_) {
              if (unique.isNotEmpty) _add(unique.first);
            },
          ),
          if (!isDefault && _picked.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('To text several people at once, make this your default messaging app. '
                  'Otherwise the first one opens in your Messages app.', style: TextStyle(color: c.muted)),
            ),
          if (!_phoneAllowed)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _loadPhone(ask: true),
                icon: const Icon(Icons.contacts_outlined),
                label: const Text('Also search my phone\'s contacts'),
              ),
            ),
          const SizedBox(height: 8),
          for (final s in unique)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: InitialsAvatar(s.name),
              title: Text(s.name),
              subtitle: s.name == s.address ? null : Text(s.address),
              trailing: const Icon(Icons.add_circle_outline),
              onTap: () => _add(s),
            ),
          if (q.isNotEmpty && unique.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('No one matches. Type a full phone number to text it.', style: TextStyle(color: c.muted)),
            ),
          SizedBox(height: pagePadding(context).bottom),
        ],
      ),
    );
  }
}
