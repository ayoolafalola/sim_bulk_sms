import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/sending_providers.dart';
import '../../app/theme.dart';
import '../../platform/contacts_plus/contacts_chat_service.dart';
import '../../platform/contacts_plus/contacts_plus_api.dart';
import '../account/account_controller.dart';
import '../../platform/ios_integration/ios_integration_service.dart';
import 'chats_providers.dart';

/// A Contacts++ chat inside Messages++. Sending shows the message at once;
/// if Contacts++ doesn't take it, it stays with Retry. New messages arrive
/// by push and by a light refresh of only what changed.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId, this.title, this.draft});
  final String conversationId;
  final String? title;

  /// Text to start with (e.g. shared from another app); never sent by itself.
  final String? draft;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _Outgoing {
  _Outgoing(this.clientId, this.body) : at = DateTime.now();
  final String clientId, body;
  final DateTime at;
  bool failed = false;
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _messages = <String, ChatMessage>{};
  final _outgoing = <_Outgoing>[];
  final _reply = TextEditingController();
  String? _cursor, _nextBefore, _error;
  bool _loading = true, _loadingOlder = false;
  Timer? _poll;

  ContactsChatService get _chats => ref.read(contactsChatServiceProvider);

  @override
  void initState() {
    super.initState();
    if (widget.draft != null) _reply.text = widget.draft!;
    // Recent chats appear at the top of the iPhone share sheet.
    IosIntegrationService()
        .donateConversation(id: 'chat:${widget.conversationId}', name: widget.title ?? 'Chat');
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatsProvider.notifier).markOpened(widget.conversationId);
      _chats.markRead(widget.conversationId);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final page = await _chats.messages(widget.conversationId);
      if (!mounted) return;
      setState(() {
        for (final m in page.messages) {
          _messages[m.id] = m;
        }
        _cursor = page.cursor;
        _nextBefore = page.nextBefore;
        _loading = false;
        _error = null;
      });
    } on ContactsPlusException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  /// Only what changed since the last look.
  Future<void> _refresh() async {
    if (_cursor == null) return;
    try {
      final page = await _chats.messages(widget.conversationId, changedSince: _cursor);
      if (!mounted || page.messages.isEmpty) {
        _cursor = page.cursor ?? _cursor;
        return;
      }
      setState(() {
        for (final m in page.messages) {
          _messages[m.id] = m;
          _outgoing.removeWhere((o) => o.clientId == m.clientId);
        }
        _cursor = page.cursor ?? _cursor;
      });
    } catch (_) {
      // Quiet: the next refresh tries again.
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || _nextBefore == null) return;
    _loadingOlder = true;
    try {
      final page = await _chats.messages(widget.conversationId, before: _nextBefore);
      if (!mounted) return;
      setState(() {
        for (final m in page.messages) {
          _messages[m.id] = m;
        }
        _nextBefore = page.nextBefore;
      });
    } catch (_) {
    } finally {
      _loadingOlder = false;
    }
  }

  Future<void> _send([_Outgoing? retry]) async {
    final text = retry?.body ?? _reply.text.trim();
    if (text.isEmpty) return;
    final out = retry ?? _Outgoing(ContactsChatService.newClientId(), text);
    setState(() {
      out.failed = false;
      if (retry == null) {
        _outgoing.add(out);
        _reply.clear();
      }
    });
    try {
      // Same client id on retry: Contacts++ never sends it twice.
      final sent = await _chats.sendInConversation(widget.conversationId, out.body, clientId: out.clientId);
      if (!mounted) return;
      setState(() {
        _outgoing.remove(out);
        _messages[sent.id] = sent;
      });
    } on ContactsPlusException {
      if (mounted) setState(() => out.failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(accountProvider).valueOrNull?.userId;
    final c = AppColors.of(context);
    final sorted = _messages.values.where((m) => m.type != 'system').toList()..sort((a, b) => a.at.compareTo(b.at));
    final items = <Widget>[
      for (final m in sorted)
        _Bubble(
          text: m.deleted ? 'Message deleted' : (m.body ?? _typeLabel(m.type)),
          mine: m.senderId == me,
          at: m.at,
          state: m.senderId == me ? m.state : null,
          muted: m.deleted,
        ),
      for (final o in _outgoing)
        _Bubble(text: o.body, mine: true, at: o.at, state: o.failed ? 'failed' : 'sending', onRetry: o.failed ? () => _send(o) : null),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title ?? 'Chat'),
          Text('Contacts++ chat', style: TextStyle(fontSize: 12, color: c.muted)),
        ]),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                                onPressed: () {
                                  setState(() => _loading = true);
                                  _load();
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('Try again')),
                          ]),
                        ),
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          // Reversed list: nearing the top loads older messages.
                          if (n.metrics.extentAfter < 400) _loadOlder();
                          return false;
                        },
                        child: ListView(
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                          children: items.reversed.toList(),
                        ),
                      ),
          ),
          Material(
            elevation: 3,
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _reply,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: 'Chat message'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: () => _send(),
                  icon: const Icon(Icons.send),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  static String _typeLabel(String type) => switch (type) {
        'image' => 'Photo · open in Contacts++',
        'video' => 'Video · open in Contacts++',
        'voice' => 'Voice message · open in Contacts++',
        'document' => 'Document · open in Contacts++',
        'call' => 'Call',
        _ => 'Message',
      };
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.mine, required this.at, this.state, this.onRetry, this.muted = false});
  final String text;
  final bool mine, muted;
  final DateTime at;
  final String? state;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = AppColors.of(context);
    final status = switch (state) {
      'sending' => 'Sending…',
      'failed' => 'Not sent',
      'read' => 'Read',
      'delivered' => 'Delivered',
      'sent' => 'Sent',
      _ => null,
    };
    final time = TimeOfDay.fromDateTime(at).format(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              // Chat bubbles use the primary colour; texts in SMS threads stay neutral.
              color: mine ? scheme.primary : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(text,
                style: TextStyle(
                    color: mine ? scheme.onPrimary : scheme.onSurface,
                    fontStyle: muted ? FontStyle.italic : FontStyle.normal)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text([time, if (status != null) status].join(' · '),
                  style: TextStyle(fontSize: 11, color: state == 'failed' ? scheme.error : c.muted)),
              if (onRetry != null)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
