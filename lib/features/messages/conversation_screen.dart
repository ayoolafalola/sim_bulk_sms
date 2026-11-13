import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/providers.dart';
import '../../app/settings_providers.dart';
import '../../domain/models/contact.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/messages/messages_service.dart';
import '../common/ui.dart';
import '../account/account_controller.dart';
import '../chats/chat_feed.dart';
import '../chats/chats_providers.dart';
import '../chats/merged_inbox.dart';
import '../chats/on_contacts_banner.dart';

/// Which campaign sent each of these stored texts ("1,2,3" → labels).
final _labelsProvider = FutureProvider.family<Map<int, ({int campaignId, String name})>, String>((ref, key) {
  ref.watch(dataVersionProvider);
  if (key.isEmpty) return const {};
  return ref.watch(campaignRepositoryProvider).campaignsForStoredMessages(key.split(',').map(int.parse));
});

/// The app contact for a number (if saved) and their groups.
final _contactForProvider = FutureProvider.family<({Contact? contact, List<String> groups}), String>((ref, address) async {
  ref.watch(dataVersionProvider);
  final e164 = ref.watch(phoneNormalizerProvider).normalize(address).e164;
  if (e164 == null) return (contact: null, groups: const <String>[]);
  final c = await ref.watch(contactRepositoryProvider).findByE164(e164);
  return (contact: c, groups: c == null ? const <String>[] : await ref.watch(groupRepositoryProvider).groupNamesOf(c.id!));
});

/// SIMs to choose from (needs the Phone permission; empty otherwise or on single-SIM phones).
final _simsProvider = FutureProvider<List<SimSubscription>>((ref) async {
  try {
    return await ref.watch(smsServiceProvider).getAvailableSubscriptions();
  } catch (_) {
    return const [];
  }
});

/// One conversation: bubbles with status and campaign labels, quick replies,
/// SIM choice and a reply box that stays above the keyboard. Opened for a
/// thread, or for a number (another app's "Send SMS", a notification), with an
/// optional draft. With [chatId] (the merged "All" list) the person's
/// Contacts++ chat joins the same timeline, each message marked SMS or Chat,
/// and replies go as a chat or a text.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key, this.threadId, this.address, this.draft, this.chatId});
  final int? threadId;
  final String? address, draft, chatId;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  late final _reply = TextEditingController(text: widget.draft ?? '');
  int? _threadId;
  bool _sending = false;
  int _lastCount = -1;
  int? _subId; // chosen SIM (null = phone default)
  bool _simLoaded = false;
  final _hidden = <int>{}; // deleted with Undo still possible
  ChatFeed? _feed; // the person's Contacts++ chat, in the merged view
  MessageSource _sendAs = MessageSource.chat;

  static const _quick = ['Thank you!', 'See you there', 'I\'ll call you back'];

  @override
  void initState() {
    super.initState();
    _threadId = widget.threadId;
    _resolve();
    final chatId = widget.chatId;
    if (chatId != null) {
      _feed = ChatFeed(ref.read(contactsChatServiceProvider), chatId)..addListener(_feedChanged);
      _feed!.start();
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(chatsProvider.notifier).markOpened(chatId));
    }
  }

  void _feedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _feed?.dispose();
    _reply.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final svc = ref.read(messagesServiceProvider);
    if (_threadId == null && widget.address != null && svc != null && await svc.isDefault()) {
      final id = await svc.threadIdFor(widget.address!);
      if (mounted) setState(() => _threadId = id);
    }
    _markRead();
  }

  Future<void> _markRead() async {
    final id = _threadId;
    if (id == null) return;
    await ref.read(messagesServiceProvider)?.markRead(id);
    ref.read(messagesVersionProvider.notifier).state++;
  }

  /// The SIM for this conversation: the one you chose before, else the one they last texted you on.
  Future<void> _loadSim(List<StoredMessage> msgs) async {
    _simLoaded = true;
    final id = _threadId;
    final saved = id == null ? null : await ref.read(settingsRepositoryProvider).simForThread(id);
    final lastIn = msgs.reversed.where((m) => m.incoming && (m.subId ?? -1) >= 0).firstOrNull;
    if (mounted) setState(() => _subId = saved ?? lastIn?.subId);
  }

  Future<void> _chooseSim(List<SimSubscription> sims) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final s in sims)
            ListTile(
              leading: const Icon(Icons.sim_card_outlined),
              title: Text(_simLabel(s)),
              trailing: s.id == _subId ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, s.id),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    setState(() => _subId = picked);
    if (_threadId != null) await ref.read(settingsRepositoryProvider).setSimForThread(_threadId!, picked);
  }

  static String _simLabel(SimSubscription s) =>
      ['SIM ${s.slotIndex + 1}', if (s.carrier?.isNotEmpty ?? false) s.carrier!].join(' · ');

  String? _address(List<StoredMessage> msgs) =>
      widget.address ?? (msgs.isNotEmpty ? msgs.last.address : null);

  Future<void> _send(String address, String text) async {
    final body = text.trim();
    if (body.isEmpty || _sending) return;
    final feed = _feed;
    if (feed != null && _sendAs == MessageSource.chat) {
      if (identical(text, _reply.text)) _reply.clear();
      if (!await feed.send(body) && mounted) _snack('Contacts++ didn’t take this chat. Tap Retry, or send it as a text.');
      return;
    }
    setState(() => _sending = true);
    final ok = await ref.read(messagesServiceProvider)?.send(address, body, subId: _subId) ?? false;
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      if (identical(text, _reply.text)) _reply.clear();
      ref.read(messagesVersionProvider.notifier).state++;
    } else {
      _snack('Couldn\'t send. Check your signal and try again.');
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _messageActions(StoredMessage m) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(ctx, 'copy')),
          ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text('Delete', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.body));
      _snack('Copied');
    } else if (action == 'delete') {
      // Hidden now; deleted from the phone when the Undo snackbar closes.
      final svc = ref.read(messagesServiceProvider);
      final version = ref.read(messagesVersionProvider.notifier);
      setState(() => _hidden.add(m.id));
      final closed = ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: const Text('Message deleted'), action: SnackBarAction(label: 'Undo', onPressed: () {})));
      closed.closed.then((reason) async {
        if (reason == SnackBarClosedReason.action) {
          if (mounted) setState(() => _hidden.remove(m.id));
          return;
        }
        await svc?.deleteMessage(m.id);
        version.state++;
      });
    }
  }

  Future<void> _deleteConversation() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this conversation?'),
        content: const Text('All its messages are deleted from this phone, also from other messaging apps.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.icon(onPressed: () => Navigator.pop(ctx, true), icon: const Icon(Icons.delete_outline), label: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || _threadId == null) return;
    await ref.read(messagesServiceProvider)?.deleteThread(_threadId!);
    ref.read(messagesVersionProvider.notifier).state++;
    if (mounted) context.pop();
  }

  /// Saves the number as an app contact (if needed) and returns its id.
  Future<int?> _ensureContact(String address, String suggestedName) async {
    final e164 = ref.read(phoneNormalizerProvider).normalize(address).e164;
    if (e164 == null) {
      _snack('This number can\'t be saved as a contact.');
      return null;
    }
    final existing = await ref.read(contactRepositoryProvider).findByE164(e164);
    if (existing != null) return existing.id;
    final ctrl = TextEditingController(text: suggestedName == address ? '' : suggestedName);
    if (!mounted) return null;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save contact'),
        content: TextField(controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: 'Name', helperText: address)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton.icon(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), icon: const Icon(Icons.check), label: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return null;
    final id = await ref.read(contactRepositoryProvider).add(Contact(name: name, phoneRaw: address, phoneNormalized: e164));
    ref.read(dataVersionProvider.notifier).state++;
    return id;
  }

  Future<void> _addToGroup(String address, String title) async {
    final groups = await ref.read(groupsProvider.future);
    if (!mounted) return;
    if (groups.isEmpty) {
      _snack('Create a group in Contacts first.');
      return;
    }
    final gid = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Add to group'), children: [
        for (final g in groups) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, g.id), child: Text(g.name)),
      ]),
    );
    if (gid == null) return;
    final id = await _ensureContact(address, title);
    if (id == null) return;
    await ref.read(groupRepositoryProvider).addContacts(gid, [id]);
    ref.read(dataVersionProvider.notifier).state++;
    _snack('Added to ${groups.firstWhere((g) => g.id == gid).name}');
  }

  @override
  Widget build(BuildContext context) {
    final id = _threadId;
    final isDefault = ref.watch(isDefaultSmsProvider).valueOrNull;
    final all = id == null ? const <StoredMessage>[] : (ref.watch(threadMessagesProvider(id)).valueOrNull ?? const <StoredMessage>[]);
    final msgs = all.where((m) => !_hidden.contains(m.id)).toList();
    final convo = ref.watch(conversationsProvider).valueOrNull?.where((c) => c.threadId == id).firstOrNull;
    final address = _address(msgs) ?? convo?.addresses.firstOrNull;
    final saved = address == null ? null : ref.watch(_contactForProvider(address)).valueOrNull;
    final title = convo?.name ?? saved?.contact?.name ?? address ?? 'New message';
    final labels = ref.watch(_labelsProvider([for (final m in msgs) if (!m.incoming) m.id].join(','))).valueOrNull ?? const {};
    final feed = _feed;
    final me = ref.watch(accountProvider).valueOrNull?.userId;
    // One timeline: texts and (merged view) chat messages, oldest first.
    final timeline = <({DateTime at, StoredMessage? sms, ChatMessage? chat, PendingChat? pending})>[
      for (final m in msgs) (at: m.date, sms: m, chat: null, pending: null),
      if (feed != null) ...[
        for (final m in feed.messages) (at: m.at, sms: null, chat: m, pending: null),
        for (final o in feed.pending) (at: o.at, sms: null, chat: null, pending: o),
      ],
    ]..sort((a, b) => a.at.compareTo(b.at));
    final sims = ref.watch(_simsProvider).valueOrNull ?? const <SimSubscription>[];
    final c = AppColors.of(context);

    // New texts arrived while open: they're read now.
    if (all.length != _lastCount) {
      if (_lastCount >= 0 && all.isNotEmpty && all.last.incoming) WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
      _lastCount = all.length;
    }
    if (!_simLoaded && all.isNotEmpty && sims.length > 1) _loadSim(all);
    final sim = sims.where((s) => s.id == _subId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          InitialsAvatar(title, size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
              Text(
                [if (address != null && address != title) address, ...?saved?.groups].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: c.muted, fontWeight: FontWeight.w500),
              ),
            ]),
          ),
        ]),
        actions: [
          if (address != null && isDefault != false)
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) async {
                switch (v) {
                  case 'save':
                    if (await _ensureContact(address, title) != null) _snack('Saved to contacts');
                  case 'group':
                    await _addToGroup(address, title);
                  case 'delete':
                    await _deleteConversation();
                }
              },
              itemBuilder: (_) => [
                if (saved?.contact == null) const PopupMenuItem(value: 'save', child: Text('Add to contacts')),
                const PopupMenuItem(value: 'group', child: Text('Add to group…')),
                if (id != null) const PopupMenuItem(value: 'delete', child: Text('Delete conversation')),
              ],
            ),
        ],
      ),
      body: Column(children: [
        if (address != null) OnContactsBanner(phone: address, name: title),
        Expanded(
          child: isDefault == false
              ? _NotDefault(address: address, draft: _reply.text)
              : timeline.isEmpty
                  ? (feed != null && !feed.loaded
                      ? const Center(child: CircularProgressIndicator())
                      : const EmptyState(icon: Icons.chat_bubble_outline, title: 'No messages yet', text: 'Say hello.'))
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      itemCount: timeline.length,
                      itemBuilder: (context, i) {
                        final e = timeline[timeline.length - 1 - i];
                        final prev = timeline.length - 2 - i >= 0 ? timeline[timeline.length - 2 - i] : null;
                        final newDay = prev == null || !_sameDay(prev.at, e.at);
                        final m = e.sms;
                        if (m == null) {
                          final cm = e.chat;
                          final p = e.pending;
                          return Column(children: [
                            if (newDay) _DayLabel(e.at),
                            cm != null
                                ? _ChatBubble(
                                    text: cm.deleted ? 'Message deleted' : (cm.body ?? _chatTypeLabel(cm.type)),
                                    mine: cm.senderId == me,
                                    at: cm.at,
                                    state: cm.senderId == me ? cm.state : null,
                                    muted: cm.deleted,
                                    onLongPress: cm.body == null ? null : () => _copy(cm.body!),
                                  )
                                : _ChatBubble(
                                    text: p!.body,
                                    mine: true,
                                    at: p.at,
                                    state: p.failed ? 'failed' : 'sending',
                                    onRetry: p.failed ? () => feed!.send(p.body, p) : null,
                                  ),
                          ]);
                        }
                        final label = labels[m.id];
                        return Column(children: [
                          if (newDay) _DayLabel(m.date),
                          if (label != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                style: TextButton.styleFrom(minimumSize: const Size(0, 32), visualDensity: VisualDensity.compact),
                                onPressed: () => context.push('/campaigns/${label.campaignId}'),
                                icon: const Icon(Icons.campaign_outlined, size: 16),
                                label: Text('Campaign · ${label.name}', style: const TextStyle(fontSize: 12)),
                              ),
                            ),
                          _Bubble(
                            m,
                            showSource: feed != null,
                            onRetry: m.status == StoredStatus.failed && address != null ? () => _send(address, m.body) : null,
                            onLongPress: () => _messageActions(m),
                          ),
                        ]);
                      },
                    ),
        ),
        if (isDefault != false && address != null) ...[
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              if (feed != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: Icon(_sendAs == MessageSource.chat ? Icons.forum_outlined : Icons.sms_outlined, size: 18),
                    label: Text(_sendAs == MessageSource.chat ? 'Send as Chat' : 'Send as SMS'),
                    tooltip: 'Switch between a Contacts++ chat and a text',
                    onPressed: () => setState(() =>
                        _sendAs = _sendAs == MessageSource.chat ? MessageSource.sms : MessageSource.chat),
                  ),
                ),
              if (sims.length > 1 && (feed == null || _sendAs == MessageSource.sms))
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Icons.sim_card_outlined, size: 18),
                    label: Text(sim == null ? 'Default SIM' : _simLabel(sim)),
                    onPressed: () => _chooseSim(sims),
                  ),
                ),
              for (final q in _quick)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(label: Text(q), onPressed: () => _send(address, q)),
                ),
            ]),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: TextField(
                    controller: _reply,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: feed != null && _sendAs == MessageSource.chat ? 'Chat message' : 'Text message',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: c.line)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: c.line)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
                  onPressed: _sending ? null : () => _send(address, _reply.text),
                  icon: const Icon(Icons.send),
                ),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _snack('Copied');
  }

  static String _chatTypeLabel(String type) => switch (type) {
        'image' => 'Photo · open in Contacts++',
        'video' => 'Video · open in Contacts++',
        'voice' => 'Voice message · open in Contacts++',
        'document' => 'Document · open in Contacts++',
        'call' => 'Call',
        _ => 'Message',
      };
}

/// "SMS" or "Chat" under a bubble in the merged timeline.
class _SourceTag extends StatelessWidget {
  const _SourceTag(this.source);
  final MessageSource source;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final chat = source == MessageSource.chat;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(chat ? Icons.forum_outlined : Icons.sms_outlined, size: 12, color: chat ? Theme.of(context).colorScheme.tertiary : c.muted),
        const SizedBox(width: 3),
        Text(chat ? 'Chat' : 'SMS',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: chat ? Theme.of(context).colorScheme.tertiary : c.muted)),
        const SizedBox(width: 4),
      ]),
    );
  }
}

/// A Contacts++ chat message in the merged timeline: same shape as a text,
/// in the chat colour, marked "Chat".
class _ChatBubble extends StatelessWidget {
  const _ChatBubble(
      {required this.text, required this.mine, required this.at, this.state, this.onRetry, this.onLongPress, this.muted = false});
  final String text;
  final bool mine, muted;
  final DateTime at;
  final String? state;
  final VoidCallback? onRetry, onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = AppColors.of(context);
    final time = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final status = switch (state) {
      'sending' => 'Sending…',
      'failed' => 'Not sent · tap to try again',
      'read' => '$time · Read',
      'delivered' => '$time · Delivered',
      'sent' => '$time · Sent',
      _ => time,
    };
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: GestureDetector(
          onTap: onRetry,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: mine ? scheme.tertiary : scheme.tertiaryContainer,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(20), topRight: const Radius.circular(20),
                    bottomLeft: Radius.circular(mine ? 20 : 6), bottomRight: Radius.circular(mine ? 6 : 20),
                  ),
                ),
                child: Text(text,
                    style: TextStyle(
                        color: mine ? scheme.onTertiary : scheme.onTertiaryContainer,
                        fontSize: 15,
                        height: 1.4,
                        fontStyle: muted ? FontStyle.italic : FontStyle.normal)),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const _SourceTag(MessageSource.chat),
                  Text(status,
                      style: TextStyle(
                          fontSize: 11,
                          color: state == 'failed' ? scheme.error : c.muted,
                          fontWeight: state == 'failed' ? FontWeight.w700 : FontWeight.w400)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.date);
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final label = day == today
        ? 'Today'
        : day == today.subtract(const Duration(days: 1))
            ? 'Yesterday'
            : '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][date.weekday - 1]} ${date.day}/${date.month}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(child: StatusTag(label)),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {this.onRetry, this.onLongPress, this.showSource = false});
  final StoredMessage m;
  final VoidCallback? onRetry, onLongPress;
  /// Merged timeline: mark it "SMS".
  final bool showSource;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = AppColors.of(context);
    final mine = !m.incoming;
    final time = '${m.date.hour.toString().padLeft(2, '0')}:${m.date.minute.toString().padLeft(2, '0')}';
    final status = switch (m.status) {
      StoredStatus.received => time,
      StoredStatus.sending => 'Sending…',
      StoredStatus.sent => '$time · Sent',
      StoredStatus.delivered => '$time · Delivered',
      StoredStatus.failed => 'Not sent · tap to try again',
    };
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: GestureDetector(
          onTap: onRetry,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: mine ? scheme.primary : c.surface,
                  border: mine ? null : Border.all(color: c.line),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(20), topRight: const Radius.circular(20),
                    bottomLeft: Radius.circular(mine ? 20 : 6), bottomRight: Radius.circular(mine ? 6 : 20),
                  ),
                ),
                child: Text(m.body,
                    style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface, fontSize: 15, height: 1.4)),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (showSource) const _SourceTag(MessageSource.sms),
                  Text(status,
                      style: TextStyle(fontSize: 11, color: m.status == StoredStatus.failed ? scheme.error : c.muted,
                          fontWeight: m.status == StoredStatus.failed ? FontWeight.w700 : FontWeight.w400)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Opened for a number while this isn't the default messaging app.
class _NotDefault extends ConsumerWidget {
  const _NotDefault({required this.address, required this.draft});
  final String? address;
  final String draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EmptyState(
        icon: Icons.forum_outlined,
        title: 'Send from your Messages app',
        text: 'This app isn\'t your default messaging app, so texts are sent from your Messages app.',
        action: address == null
            ? null
            : FilledButton.icon(
                onPressed: () => ref.read(messagesAppProvider)?.open(address!, draft),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Messages app'),
              ),
      );
}
