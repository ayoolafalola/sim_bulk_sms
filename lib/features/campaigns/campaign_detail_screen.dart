import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../data/repositories/attempt_repository.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';
import '../../platform/sms/sms_capability_service.dart';
import 'campaign_labels.dart';

/// Review, send and follow one campaign. Every figure comes from persisted
/// recipient rows; nothing is shown as sent unless the platform reported it.
class CampaignDetailScreen extends ConsumerStatefulWidget {
  const CampaignDetailScreen({super.key, required this.campaignId});
  final int campaignId;

  @override
  ConsumerState<CampaignDetailScreen> createState() => _CampaignDetailScreenState();
}

class _CampaignDetailScreenState extends ConsumerState<CampaignDetailScreen> {
  static const _live = {CampaignStatus.running, CampaignStatus.awaitingUserAction};
  Timer? _poll;
  bool _busy = false;

  int get _id => widget.campaignId;

  @override
  void initState() {
    super.initState();
    // Android results arrive asynchronously via callbacks: refresh while sending.
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = ref.read(campaignProvider(_id)).valueOrNull?.status;
      if (s != null && _live.contains(s)) _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _refresh() => ref.read(dataVersionProvider.notifier).state++;
  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _send(Campaign c, SmsCapabilities caps, List<CampaignRecipient> recipients) async {
    final pending = recipients.where((r) => r.status == RecipientStatus.pending).toList();
    final orch = ref.read(sendOrchestratorProvider);
    if (caps.platform == SmsPlatform.ios && caps.usesComposerHandoff) {
      if (c.status == CampaignStatus.ready &&
          !await _confirm('Start sending?',
              'Messages will open one at a time. You tap Send in Messages for each of the ${pending.length} recipients.',
              'Start')) {
        return;
      }
      setState(() => _busy = true);
      try {
        final r = await orch.sendNextViaComposer(_id);
        _snack(switch (r) {
          null => 'Nothing left to send.',
          RecipientStatus.sent => 'Handed to Messages. iOS does not report delivery.',
          RecipientStatus.cancelled => 'Not sent: the message was cancelled.',
          _ => 'Not sent.',
        });
      } catch (e) {
        _snack('$e');
      } finally {
        if (mounted) setState(() => _busy = false);
        _refresh();
      }
      return;
    }
    if (caps.platform == SmsPlatform.android && caps.canSendDirectly) {
      final est = estimateCampaign([for (final r in pending) r.renderedMessage]);
      int? subscriptionId;
      if (caps.canSelectSim) {
        final subs = await ref.read(smsServiceProvider).getAvailableSubscriptions();
        if (!mounted) return;
        if (subs.length > 1) {
          subscriptionId = await _pickSim(subs);
          if (subscriptionId == null) return;
        } else if (subs.length == 1) {
          subscriptionId = subs.single.id;
        }
      }
      if (!await _confirm(
          c.status == CampaignStatus.paused ? 'Resume sending?' : 'Send now?',
          'Send ${pending.length} messages (about ${est.totalSegments} SMS segments) through your SIM. '
              'Your carrier charges apply. You can pause at any time.',
          'Send')) {
        return;
      }
      unawaited(orch.runAndroid(_id, subscriptionId: subscriptionId).then((_) => _refresh(), onError: (Object e) {
        _snack('$e');
        _refresh();
      }));
      // Let markRunning land so the button flips to Pause.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      _refresh();
      return;
    }
    if (caps.blocker == DirectSendBlocker.permissionDenied) {
      final ok = await ref.read(smsServiceProvider).requestRequiredPermissions();
      ref.invalidate(capabilitiesProvider);
      _snack(ok ? 'Permission granted. Tap Send again.' : 'SMS permission was not granted.');
      return;
    }
    _snack(caps.messageForUser ?? 'Sending is not available on this device.');
  }

  Future<int?> _pickSim(List<SimSubscription> subs) => showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(title: const Text('Send from which SIM?'), children: [
          for (final s in subs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s.id),
              child: Text('SIM ${s.slotIndex + 1}${s.label != null ? ' · ${s.label}' : ''}'
                  '${s.carrier != null ? ' · ${s.carrier}' : ''}'),
            ),
        ]),
      );

  Future<void> _cancel() async {
    if (!await _confirm('Cancel campaign?',
        'Messages not yet sent will be cancelled. Messages already sent cannot be recalled.', 'Cancel campaign')) {
      return;
    }
    await ref.read(sendOrchestratorProvider).cancel(_id);
    _refresh();
  }

  Future<void> _delete() async {
    if (!await _confirm('Delete campaign?', 'Its recipient list and send history will be removed.', 'Delete')) return;
    await ref.read(campaignRepositoryProvider).delete(_id);
    _refresh();
    if (mounted) context.go('/');
  }

  Future<void> _recipientAction(CampaignRecipient r, String action) async {
    final attempts = ref.read(attemptRepositoryProvider);
    try {
      switch (action) {
        case 'retry':
          await attempts.requeue(r.id);
        case 'retry_unknown':
          if (!await _confirm('Send again?',
              'This message may already have reached ${r.name}. Sending again could deliver it twice.', 'Send again')) {
            return;
          }
          await attempts.requeue(r.id, acknowledgeDuplicateRisk: true);
        case 'mark_sent':
          await attempts.resolveUnknown(r.id, RecipientStatus.sent);
        case 'mark_failed':
          await attempts.resolveUnknown(r.id, RecipientStatus.failed);
      }
      await attempts.finalizeCampaign(_id);
    } on AttemptRefusedException catch (e) {
      _snack(e.message);
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final campaign = ref.watch(campaignProvider(_id));
    final recipients = ref.watch(campaignRecipientsProvider(_id));
    final caps = ref.watch(capabilitiesProvider);
    return campaign.when(
      loading: () => Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: const Center(child: Text('Could not load this campaign.'))),
      data: (c) {
        if (c == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This campaign no longer exists.')));
        final list = recipients.valueOrNull ?? const <CampaignRecipient>[];
        final editable = c.status == CampaignStatus.draft || c.status == CampaignStatus.ready;
        return Scaffold(
          appBar: AppBar(title: Text(c.name), actions: [
            if (editable)
              IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit), onPressed: () => context.go('/campaigns/$_id/edit')),
            if (!_live.contains(c.status))
              IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          ]),
          bottomNavigationBar: SafeArea(child: _actions(c, caps, list)),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Chip(label: Text(campaignStatusLabel(c.status))),
              const SizedBox(width: 8),
              Text('${c.recipientCount} recipients'),
            ]),
            const SizedBox(height: 8),
            Text(c.messageTemplate, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            StatusCounts(list),
            const SizedBox(height: 8),
            if (c.status == CampaignStatus.draft)
              const Text('This campaign has no recipients yet. Edit it to choose who receives it.'),
            for (final r in list) _RecipientTile(r, onAction: (a) => _recipientAction(r, a)),
          ]),
        );
      },
    );
  }

  Widget _actions(Campaign c, AsyncValue<SmsCapabilities> caps, List<CampaignRecipient> list) {
    final buttons = <Widget>[];
    final cap = caps.valueOrNull;
    final hasPending = list.any((r) => r.status == RecipientStatus.pending);
    String? note;
    switch (c.status) {
      case CampaignStatus.ready || CampaignStatus.paused || CampaignStatus.awaitingUserAction:
        if (cap == null) {
          note = caps.isLoading ? null : 'Messaging is unavailable on this device.';
        } else if (hasPending) {
          final ios = cap.platform == SmsPlatform.ios;
          final canTry = cap.canSendDirectly || cap.usesComposerHandoff || cap.blocker == DirectSendBlocker.permissionDenied;
          if (!canTry) note = cap.messageForUser ?? 'Sending is not available on this device.';
          buttons.add(FilledButton.icon(
            onPressed: (!canTry || _busy) ? null : () => _send(c, cap, list),
            icon: const Icon(Icons.send),
            label: Text(ios
                ? 'Open next message'
                : cap.blocker == DirectSendBlocker.permissionDenied
                    ? 'Allow SMS permission'
                    : c.status == CampaignStatus.paused ? 'Resume' : 'Send'),
          ));
        }
        if (c.status != CampaignStatus.ready) {
          buttons.add(OutlinedButton(onPressed: _cancel, child: const Text('Cancel campaign')));
        }
      case CampaignStatus.running:
        buttons.add(FilledButton.tonalIcon(
          onPressed: () {
            ref.read(sendOrchestratorProvider).pause();
            _snack('Pausing after the current message.');
          },
          icon: const Icon(Icons.pause),
          label: const Text('Pause'),
        ));
        buttons.add(OutlinedButton(onPressed: _cancel, child: const Text('Cancel campaign')));
      default:
        break;
    }
    if (buttons.isEmpty && note == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (note != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(note, textAlign: TextAlign.center)),
        Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: buttons),
      ]),
    );
  }
}

class StatusCounts extends StatelessWidget {
  const StatusCounts(this.recipients, {super.key});
  final List<CampaignRecipient> recipients;

  @override
  Widget build(BuildContext context) {
    final counts = <RecipientStatus, int>{};
    for (final r in recipients) {
      counts[r.status] = (counts[r.status] ?? 0) + 1;
    }
    return Wrap(spacing: 8, runSpacing: 4, children: [
      for (final s in RecipientStatus.values)
        if ((counts[s] ?? 0) > 0) Chip(label: Text('${recipientStatusLabel(s)}: ${counts[s]}')),
    ]);
  }
}

class _RecipientTile extends StatelessWidget {
  const _RecipientTile(this.r, {required this.onAction});
  final CampaignRecipient r;
  final void Function(String) onAction;

  @override
  Widget build(BuildContext context) {
    final items = <PopupMenuEntry<String>>[
      if (r.status == RecipientStatus.failed || r.status == RecipientStatus.cancelled)
        const PopupMenuItem(value: 'retry', child: Text('Send again')),
      if (r.status == RecipientStatus.unknown) ...const [
        PopupMenuItem(value: 'mark_sent', child: Text('I checked: it was sent')),
        PopupMenuItem(value: 'mark_failed', child: Text('I checked: it was not sent')),
        PopupMenuItem(value: 'retry_unknown', child: Text('Send again (may duplicate)')),
      ],
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(r.name),
      subtitle: Text(r.phone),
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(r.name),
          content: Text('${r.renderedMessage}\n\nStatus: ${recipientStatusLabel(r.status)}'
              '${r.attemptCount > 0 ? ' · attempts: ${r.attemptCount}' : ''}'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(recipientStatusLabel(r.status)),
        if (items.isNotEmpty) PopupMenuButton<String>(onSelected: onAction, itemBuilder: (_) => items),
      ]),
    );
  }
}
