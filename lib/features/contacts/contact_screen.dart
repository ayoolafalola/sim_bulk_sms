import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/settings_providers.dart';
import '../../app/theme.dart';
import '../../domain/models/contact.dart';
import '../../domain/models/statuses.dart';
import '../common/page_layout.dart';
import '../common/ui.dart';
import 'birthday_field.dart';

final _detailsProvider = FutureProvider.family<({ContactDetails? d, List<String> groups}), int>((ref, id) async {
  ref.watch(dataVersionProvider);
  final d = await ref.watch(contactRepositoryProvider).details(id);
  return (d: d, groups: d == null ? const <String>[] : await ref.watch(groupRepositoryProvider).groupNamesOf(id));
});

/// Everything about a person: numbers and emails (choose which to use), dates,
/// company, address, notes, groups and consent. Phone contacts are edited in the
/// phone's Contacts app (changes sync back); app-only contacts are edited here.
class ContactScreen extends ConsumerWidget {
  const ContactScreen({super.key, required this.contactId});
  final int contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_detailsProvider(contactId));
    return data.when(
      loading: () => Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: const Center(child: Text('Could not load this contact.'))),
      data: (r) {
        final d = r.d;
        if (d == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This contact no longer exists.')));
        }
        return _Body(details: d, groups: r.groups);
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.details, required this.groups});
  final ContactDetails details;
  final List<String> groups;

  Contact get c => details.contact;

  void _refresh(WidgetRef ref) => ref.read(dataVersionProvider.notifier).state++;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppColors.of(context);
    final repo = ref.read(contactRepositoryProvider);
    final sub = [c.jobTitle, c.organization].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final texting = c.phoneNormalized ?? c.phoneRaw;

    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(
          tooltip: 'Edit',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () async {
            if (c.fromPhone) {
              final ok = await ref.read(phoneContactsServiceProvider).edit(c);
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Edit this contact in your phone\'s Contacts app; changes appear here automatically.')));
              }
            } else {
              await _editAppContact(context, ref);
            }
          },
        ),
      ]),
      body: ListView(padding: pagePadding(context, extra: 24).copyWith(top: 0), children: [
        Center(child: InitialsAvatar(c.name, size: 80)),
        const SizedBox(height: 12),
        Text(c.name, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        if (sub.isNotEmpty) Text(sub, textAlign: TextAlign.center, style: TextStyle(color: colors.muted)),
        const SizedBox(height: 8),
        Center(
          child: StatusTag(c.fromPhone ? 'From your phone' : 'Saved in this app',
              tone: c.fromPhone ? Tone.info : Tone.neutral),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: texting.isEmpty
                  ? null
                  : () => context.push(Uri(path: '/messages/compose', queryParameters: {'to': texting}).toString()),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Message'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _addToGroup(context, ref),
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Add to group'),
            ),
          ),
        ]),
        if (details.phones.isNotEmpty) ...[
          SectionLabel(details.phones.length > 1 ? 'Phone numbers · tap to text this one' : 'Phone number'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final p in details.phones)
                ListTile(
                  leading: Icon(Icons.phone_outlined, color: colors.muted),
                  title: Text(p.value),
                  subtitle: p.label == null || p.label!.isEmpty ? null : Text(p.label!),
                  trailing: (p.normalized ?? p.value) == texting ? const StatusTag('Used for texts', tone: Tone.success) : null,
                  onTap: details.phones.length < 2 || p.normalized == null
                      ? null
                      : () async {
                          await repo.preferPhone(c.id!, p);
                          _refresh(ref);
                        },
                ),
            ]),
          ),
        ],
        if (details.emails.isNotEmpty) ...[
          SectionLabel(details.emails.length > 1 ? 'Emails · tap to use this one' : 'Email'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final e in details.emails)
                ListTile(
                  leading: Icon(Icons.email_outlined, color: colors.muted),
                  title: Text(e.value),
                  subtitle: e.label == null || e.label!.isEmpty ? null : Text(e.label!),
                  trailing: e.value == c.email ? const StatusTag('Used for email', tone: Tone.info) : null,
                  onTap: details.emails.length < 2
                      ? null
                      : () async {
                          await repo.preferEmail(c.id!, e.value);
                          _refresh(ref);
                        },
                ),
            ]),
          ),
        ],
        if (details.dates.isNotEmpty || c.birthday != null) ...[
          const SectionLabel('Dates'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final d in details.dates.isNotEmpty
                  ? details.dates
                  : [ContactDate(kind: 'birthday', value: c.birthday!, label: 'Birthday')])
                ListTile(
                  leading: Icon(d.kind == 'birthday' ? Icons.cake_outlined : Icons.event_outlined, color: colors.muted),
                  title: Text(formatContactDate(d.value)),
                  subtitle: Text(d.label?.isNotEmpty ?? false ? d.label! : (d.kind == 'birthday' ? 'Birthday' : 'Date')),
                ),
            ]),
          ),
        ],
        if ((c.address ?? '').isNotEmpty || (c.note ?? '').isNotEmpty) ...[
          const SectionLabel('More'),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              if ((c.address ?? '').isNotEmpty)
                ListTile(leading: Icon(Icons.place_outlined, color: colors.muted), title: Text(c.address!)),
              if ((c.note ?? '').isNotEmpty)
                ListTile(leading: Icon(Icons.notes, color: colors.muted), title: Text(c.note!)),
            ]),
          ),
        ],
        const SectionLabel('Groups'),
        if (groups.isEmpty)
          Text('Not in any group yet.', style: TextStyle(color: colors.muted))
        else
          Wrap(spacing: 6, runSpacing: 6, children: [for (final g in groups) StatusTag(g, tone: Tone.success)]),
        const SectionLabel('Messages from campaigns'),
        SegmentedButton<ConsentStatus>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ConsentStatus.unknown, label: Text('Not asked')),
            ButtonSegment(value: ConsentStatus.optedIn, label: Text('Opted in')),
            ButtonSegment(value: ConsentStatus.optedOut, label: Text('Opted out')),
          ],
          selected: {c.consent},
          onSelectionChanged: (v) async {
            await repo.setConsent(c.id!, v.first);
            _refresh(ref);
          },
        ),
        if (c.phoneNormalized != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                await repo.suppress(c.phoneNormalized!, reason: 'added manually');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${c.name} won\'t receive campaigns.')));
                }
              },
              icon: const Icon(Icons.block),
              label: const Text('Never send campaigns to this number'),
            ),
          ),
        const SizedBox(height: 16),
        if (c.fromPhone)
          Text('This contact comes from your phone. Delete it in your phone\'s Contacts app and it disappears here too.',
              style: TextStyle(color: colors.muted, fontSize: 13))
        else
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => context.pop('delete'), // the Contacts tab deletes it with Undo
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete contact'),
          ),
      ]),
    );
  }

  Future<void> _addToGroup(BuildContext context, WidgetRef ref) async {
    final groups = await ref.read(groupsProvider.future);
    if (!context.mounted) return;
    if (groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Create a group in Contacts › Groups first.')));
      return;
    }
    final gid = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Add to group'), children: [
        for (final g in groups) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, g.id), child: Text(g.name)),
      ]),
    );
    if (gid == null) return;
    await ref.read(groupRepositoryProvider).addContacts(gid, [c.id!]);
    _refresh(ref);
  }

  Future<void> _editAppContact(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(text: c.name), phone = TextEditingController(text: c.phoneRaw),
        email = TextEditingController(text: c.email ?? ''), company = TextEditingController(text: c.organization ?? '');
    String? birthday = c.birthday;
    final normalizer = ref.read(phoneNormalizerProvider);
    String? error;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Edit contact', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 12),
              TextField(controller: phone, keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: 'Phone number', errorText: error)),
              const SizedBox(height: 12),
              TextField(controller: email, keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email')),
              const SizedBox(height: 12),
              TextField(controller: company, decoration: const InputDecoration(labelText: 'Company')),
              const SizedBox(height: 12),
              BirthdayField(value: birthday, onChanged: (v) => setSheet(() => birthday = v)),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () async {
                  final n = phone.text.trim().isEmpty ? null : normalizer.normalize(phone.text);
                  if (n != null && !n.isValid) {
                    setSheet(() => error = 'This is not a valid phone number.');
                    return;
                  }
                  if (n == null && email.text.trim().isEmpty) {
                    setSheet(() => error = 'Add a phone number or an email.');
                    return;
                  }
                  try {
                    await ref.read(contactRepositoryProvider).update(Contact(
                        id: c.id, name: name.text.trim().isEmpty ? c.name : name.text.trim(),
                        phoneRaw: phone.text.trim(), phoneNormalized: n?.e164,
                        email: email.text.trim().isEmpty ? null : email.text.trim(),
                        organization: company.text.trim().isEmpty ? null : company.text.trim(),
                        birthday: birthday,
                      ));
                  } on DuplicateContactException {
                    setSheet(() => error = 'Another contact already has this number.');
                    return;
                  }
                  if (ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('Save'),
              ),
            ]),
          ),
        ),
      ),
    );
    if (saved == true) _refresh(ref);
  }
}
