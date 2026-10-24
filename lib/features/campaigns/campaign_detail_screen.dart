import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app/capability_providers.dart';
import '../../app/providers.dart';
import '../../app/sending_providers.dart';
import '../../data/repositories/attempt_repository.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/pro.dart';
import '../../platform/email/email_sender.dart';
import '../../domain/models/statuses.dart';
import '../../domain/services/campaign_planner.dart';
import '../../platform/sms/ios_sms_service.dart';
import '../../platform/sms/sms_capability_service.dart';
import '../../domain/services/schedule_calculator.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../domain/services/send_limits.dart';
import 'campaign_composer.dart';
import '../../app/app_info.dart';
import '../../app/theme.dart';
import '../common/ui.dart';
import 'campaign_labels.dart';
import '../common/page_layout.dart';
import '../pro/pro_screen.dart';

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
  DateTime? _watchUntil;
  bool _wasLive = false;
  bool _busy = false;

  int get _id => widget.campaignId;

  @override
  void initState() {
    super.initState();
    // Android results arrive asynchronously via callbacks: refresh while sending.
    // Only this campaign's data is re-read, and the screen keeps showing the current
    // numbers while it does (no reload of the whole app, no spinner flashing).
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      final s = ref.read(campaignProvider(_id)).valueOrNull?.status;
      final starting = _watchUntil != null && DateTime.now().isBefore(_watchUntil!);
      final live = (s != null && _live.contains(s)) || starting;
      if (live) {
        ref.invalidate(campaignProvider(_id));
        ref.invalidate(campaignRecipientsProvider(_id));
      } else if (_wasLive) {
        _refresh(); // just finished: update the dashboard and the rest once
      }
      _wasLive = live;
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

  /// Sends the pending emails by themselves (texts stay for you). Returns false if it couldn't start.
  Future<bool> _sendEmailsHere(int count) async {
    setState(() => _busy = true);
    _snack('Sending $count ${count == 1 ? 'email' : 'emails'}…');
    try {
      final hit = await ref.read(sendOrchestratorProvider).runEmails(_id);
      if (hit != null) {
        _snack('${limitLabel(hit.kind, email: true)} reached. Emails resume at ${formatWhen(hit.resumeAt)}.');
      }
      return true;
    } on EmailNotReadyException catch (e) {
      _snack(e.message);
      return false;
    } catch (e) {
      _snack('$e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _send(Campaign c, SmsCapabilities caps, List<CampaignRecipient> recipients) async {
    final allPending = recipients.where((r) => r.status == RecipientStatus.pending).toList();
    final pending = allPending.where((r) => !r.isEmail).toList();
    final emails = allPending.where((r) => r.isEmail).length;
    final orch = ref.read(sendOrchestratorProvider);
    final cfg = await ref.read(settingsRepositoryProvider).loadEmail();
    if (emails > 0) {
      if (!cfg.ready) {
        _snack('Set up email first: Settings › Email.');
        if (mounted) context.push('/settings/email');
        return;
      }
    }
    final directSms = caps.platform == SmsPlatform.android && caps.canSendDirectly;
    if (emails > 0 && (pending.isEmpty || !directSms)) {
      // Emails go by themselves; texts (if any) then follow the usual flow below.
      if (pending.isEmpty &&
          !await _confirm('Send $emails ${emails == 1 ? 'email' : 'emails'}?',
              'They go out through ${cfg.providerLabel} from ${cfg.senderAddress}.',
              'Send')) {
        return;
      }
      final bg = ref.read(backgroundSendServiceProvider);
      if (pending.isEmpty && bg != null) {
        if (!await bg.startSend(_id)) {
          _snack('Could not start sending. Please try again.');
          return;
        }
        _snack('Sending. You can leave the app; progress shows in a notification.');
        _watchUntil = DateTime.now().add(const Duration(seconds: 15));
        _refresh();
        return;
      }
      if (!await _sendEmailsHere(emails) || pending.isEmpty) return;
    }
    if (caps.platform == SmsPlatform.ios && caps.usesComposerHandoff) {
      if (pending.length > 1 && await orch.canBatch(_id)) {
        final mode = await _chooseBatch();
        if (mode == 'all') {
          await _composerBatchNext();
          return;
        }
        if (mode == null) return;
      } else if (c.status == CampaignStatus.ready &&
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
          RecipientStatus.sent => 'Handed to Messages. Delivery isn\'t reported on this phone.',
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
      final signature = await ref.read(settingsRepositoryProvider).signature();
      final est = estimateCampaign([for (final r in pending) withSignature(r.renderedMessage, signature)]);
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
      final timing = await _timingText(pending.length);
      if (!mounted) return;
      if (!await _confirm(
          c.status == CampaignStatus.paused ? 'Resume sending?' : 'Send now?',
          'Send ${pending.length} messages (about ${est.totalSegments} SMS segments) through your SIM'
              '${emails > 0 ? ' and $emails ${emails == 1 ? 'email' : 'emails'}' : ''}. '
              '$timing\n\nYour carrier charges apply. You can pause at any time.',
          'Send')) {
        return;
      }
      final bg = ref.read(backgroundSendServiceProvider);
      if (bg != null) {
        // The foreground service sends, so it keeps going if you leave the app.
        if (!await bg.startSend(_id, subscriptionId: subscriptionId)) {
          _snack('Could not start sending. Please try again.');
          return;
        }
        _snack('Sending. You can leave the app; progress shows in a notification.');
      } else {
        unawaited(orch.runAndroid(_id, subscriptionId: subscriptionId).then((_) => _refresh(), onError: (Object e) {
          _snack('$e');
          _refresh();
        }));
      }
      // Keep refreshing until the sender marks the campaign running.
      _watchUntil = DateTime.now().add(const Duration(seconds: 15));
      _refresh();
      return;
    }
    if (caps.platform == SmsPlatform.android && caps.usesComposerHandoff) {
      // Everyone gets the same text: offer to put up to 20 numbers in one message.
      if (pending.length > 1 && await orch.canBatch(_id)) {
        final mode = await _chooseBatch();
        if (mode == 'all') await _manualBatchNext();
        if (mode == 'one') await _manualNext();
        return;
      }
      if (c.status == CampaignStatus.ready &&
          !await _confirm('Send through your Messages app?',
              'Automatic sending is off, so each of the ${pending.length} messages opens in your Messages app with '
                  'everything filled in. Tap Send there, then come back and confirm.',
              'Start')) {
        return;
      }
      await _manualNext();
      return;
    }
    _snack(caps.messageForUser ?? 'Sending is not available on this device.');
  }

  /// How many numbers go in one Messages-app message when sending to all at once.
  static const batchSize = 20;

  /// "20 at once" or "one at a time" (null = cancel), when everyone gets the same text.
  Future<String?> _chooseBatch() => showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Send through Messages'),
          content: const Text('Everyone gets the same text, so you can send it to up to $batchSize people at once, '
              'or one person at a time.\n\n'
              'At once: Messages may send it as a group message. Everyone can then see each other\'s numbers and '
              'replies, and it may cost more (MMS). That depends on your Messages settings.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'one'), child: const Text('One at a time')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'all'), child: const Text('$batchSize at once')),
          ],
        ),
      );

  /// iPhone / iPad, all at once: one composer with up to [batchSize] recipients. The composer itself
  /// reports whether Send was tapped, so there's nothing to ask afterwards.
  Future<void> _composerBatchNext() async {
    final orch = ref.read(sendOrchestratorProvider);
    final composer = ref.read(smsServiceProvider);
    if (composer is! IosSmsService) return;
    setState(() => _busy = true);
    try {
      final b = await orch.startManualBatch(_id, size: batchSize, platform: 'ios');
      if (b == null) {
        _snack('Everyone has been handled.');
        return;
      }
      final res = await composer.composeMany(b.phones, b.body);
      await orch.finishManualBatch(b.attemptIds, sent: res == 'sent', errorCode: res == 'sent' ? 'composer_sent' : res);
      _snack(res == 'sent'
          ? 'Sent to people ${b.from}–${b.to} of ${b.total}.'
          : 'Not sent to people ${b.from}–${b.to}. You can try again.');
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  /// Messages-app fallback, all at once: open the next batch, then ask whether it was sent.
  Future<void> _manualBatchNext() async {
    final orch = ref.read(sendOrchestratorProvider);
    final app = ref.read(messagesAppProvider);
    if (app == null) return;
    setState(() => _busy = true);
    try {
      final b = await orch.startManualBatch(_id, size: batchSize);
      if (b == null) {
        _snack('Everyone has been handled.');
        return;
      }
      if (!await app.openMany(b.phones, b.body)) {
        await orch.finishManualBatch(b.attemptIds, sent: false, errorCode: 'no_messages_app');
        _snack('No Messages app was found to send with.');
        return;
      }
      if (!mounted) return;
      final sent = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('Did you send it to these ${b.phones.length} people?'),
          content: Text('People ${b.from}–${b.to} of ${b.total}: ${b.names.take(3).join(', ')}'
              '${b.names.length > 3 ? ' and ${b.names.length - 3} more' : ''}. '
              'The phone can\'t tell the app whether you tapped Send.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not sent')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sent')),
          ],
        ),
      );
      await orch.finishManualBatch(b.attemptIds, sent: sent == true);
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  /// Messages-app fallback: open the next message, then ask whether it was sent.
  Future<void> _manualNext() async {
    final orch = ref.read(sendOrchestratorProvider);
    final app = ref.read(messagesAppProvider);
    if (app == null) return;
    setState(() => _busy = true);
    try {
      final m = await orch.startManualSend(_id);
      if (m == null) {
        _snack('Everyone has been handled.');
        return;
      }
      if (!await app.open(m.phone, m.body)) {
        await orch.finishManualSend(m.attemptId, sent: false, errorCode: 'no_messages_app');
        _snack('No Messages app was found to send with.');
        return;
      }
      if (!mounted) return;
      // Shown when you come back from the Messages app.
      final sent = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('Did you send it to ${m.name}?'),
          content: Text('Message ${m.position} of ${m.total}. The phone can\'t tell the app whether you tapped Send.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not sent')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sent')),
          ],
        ),
      );
      await orch.finishManualSend(m.attemptId, sent: sent == true);
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  /// Automatic sending: become the default messaging app (Play only allows SMS
  /// permissions for it), then make sure the SMS permissions are granted.
  Future<void> _enableAutomatic() async {
    final messages = ref.read(messagesServiceProvider);
    if (messages == null) return;
    var ok = await messages.requestDefault();
    if (!ok) {
      await messages.openDefaultAppsSettings();
      _snack('Choose $appName under SMS app, then come back.');
      return;
    }
    ok = await ref.read(smsServiceProvider).requestRequiredPermissions();
    ref.invalidate(capabilitiesProvider);
    ref.read(backgroundStatusVersionProvider.notifier).state++;
    ref.read(messagesVersionProvider.notifier).state++;
    _snack(ok ? 'Automatic sending is on.' : 'SMS permission was not granted.');
  }

  /// "Takes about 23 min. With your hourly limit it finishes around 16:40."
  Future<String> _timingText(int messages) async {
    final cfg = await ref.read(settingsRepositoryProvider).load();
    final now = DateTime.now();
    final sent = await ref.read(attemptRepositoryProvider).sendTimesSince(now.subtract(const Duration(hours: 24)));
    final hit = checkLimits(sent: sent, now: now, settings: cfg);
    final finish = estimateFinish(messages: messages, settings: cfg, sent: sent, now: now);
    final plain = cfg.delay * (messages > 0 ? messages - 1 : 0);
    final parts = <String>['Takes about ${formatDuration(plain)} at ${cfg.delaySeconds} s between messages.'];
    if (hit != null) {
      parts.add('The ${limitLabel(hit.kind).toLowerCase()} is reached right now, so sending starts '
          'automatically at ${formatWhen(hit.resumeAt, now: now)}.');
    }
    if (finish.difference(now) > plain + const Duration(minutes: 1)) {
      parts.add('With your send limits it finishes around ${formatWhen(finish, now: now)}.');
    }
    return parts.join(' ');
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
    final c = ref.read(campaignProvider(_id)).valueOrNull;
    if (c?.status == CampaignStatus.draft) {
      // A draft has no history to lose: delete with Undo instead of asking.
      final pending = ref.read(pendingCampaignDeletesProvider.notifier);
      final repo = ref.read(campaignRepositoryProvider);
      final version = ref.read(dataVersionProvider.notifier);
      final messenger = ScaffoldMessenger.of(context);
      pending.state = {...pending.state, _id};
      context.go('/');
      final closed = messenger.showSnackBar(SnackBar(
        content: Text('Deleted draft “${c!.name}”'),
        action: SnackBarAction(label: 'Undo', onPressed: () {}),
      ));
      final id = _id;
      closed.closed.then((reason) async {
        if (reason != SnackBarClosedReason.action) await repo.delete(id);
        pending.state = {...pending.state}..remove(id);
        version.state++;
      });
      return;
    }
    if (!await _confirm('Delete campaign?', 'Its recipient list and send history will be removed.', 'Delete')) return;
    await ref.read(campaignRepositoryProvider).delete(_id);
    _refresh();
    if (mounted) context.go('/');
  }

  Future<void> _sendAgain(Campaign c) async {
    final audience = await ref.read(campaignRepositoryProvider).audience(c.id);
    if (!mounted) return;
    final mode = await showDialog<ResendMode>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Send again to…'), children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, ResendMode.sameRecipients),
          child: const ListTile(
            title: Text('The same people as before'),
            subtitle: Text('Same messages. Anyone who has since opted out or been suppressed is left out.'),
          ),
        ),
        if (!audience.isEmpty)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ResendMode.currentAudience),
            child: const ListTile(
              title: Text('Everyone in the groups now'),
              subtitle: Text('Includes people added since; messages are written again.'),
            ),
          ),
      ]),
    );
    if (mode == null) return;
    setState(() => _busy = true);
    try {
      final caps = ref.read(capabilitiesProvider).valueOrNull;
      final platform = caps?.platform == SmsPlatform.ios ? 'ios' : c.platform;
      final id = await ref.read(composerProvider).resend(c.id, mode, platform: platform);
      _refresh();
      if (mounted) context.go('/campaigns/$id');
    } on ResendRefusedException catch (e) {
      _snack(e.message);
    } on ProRequiredException catch (e) {
      if (mounted) await showProRequired(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      // Re-reads while sending keep the page as it is until the new numbers arrive.
      skipLoadingOnReload: true,
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
          body: ListView(padding: pagePadding(context, extra: 24), children: [
            // Wrap, not Row: long status labels or large text sizes must not overflow.
            Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              StatusTag(campaignStatusLabel(c.status), tone: campaignTone(c.status)),
              Text('${c.recipientCount} recipients', style: TextStyle(color: AppColors.of(context).muted)),
            ]),
            if (c.recipientCount > 0) ...[
              const SizedBox(height: 12),
              ProgressLine(
                value: list.where((r) => r.status != RecipientStatus.pending).length / c.recipientCount,
                tone: campaignTone(c.status) == Tone.danger ? Tone.danger : Tone.success,
              ),
            ],
            if (pausedReasonText(c) case final why?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  const Icon(Icons.hourglass_bottom, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(why)),
                ]),
              ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: AppColors.of(context).surface, borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.of(context).line)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (c.channel.usesEmail && (c.subject ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('Subject: ${c.subject}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                Text(c.messageTemplate, style: const TextStyle(height: 1.45)),
              ]),
            ),
            if (c.sourceCampaignId != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => context.go('/campaigns/${c.sourceCampaignId}'),
                  icon: const Icon(Icons.history),
                  label: Text(c.scheduleId != null ? 'Scheduled run · open the original' : 'Resent · open the original'),
                ),
              ),
            if (c.scheduleId == null) _ScheduleSection(campaign: c),
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
          final textsPending = list.any((r) => r.status == RecipientStatus.pending && !r.isEmail);
          final handoff = textsPending && !cap.canSendDirectly && cap.usesComposerHandoff; // iOS, or Android fallback
          final canTry = cap.canSendDirectly || cap.usesComposerHandoff || !textsPending;
          if (!canTry || (handoff && cap.platform == SmsPlatform.android)) {
            note = cap.messageForUser ?? 'Sending is not available on this device.';
          }
          final texts = list.where((r) => !r.isEmail).toList();
          final done = texts.where((r) => r.status != RecipientStatus.pending).length;
          buttons.add(FilledButton.icon(
            onPressed: (!canTry || _busy) ? null : () => _send(c, cap, list),
            icon: const Icon(Icons.send),
            label: Text(handoff
                ? 'Open next message (${done + 1} of ${texts.length})'
                : c.status == CampaignStatus.paused ? 'Resume' : 'Send'),
          ));
          if (cap.platform == SmsPlatform.android &&
              (cap.blocker == DirectSendBlocker.notDefaultApp || cap.blocker == DirectSendBlocker.permissionDenied)) {
            buttons.add(TextButton(onPressed: _enableAutomatic, child: const Text('Turn on automatic sending')));
          }
        }
        if (c.status != CampaignStatus.ready) {
          buttons.add(OutlinedButton(onPressed: _cancel, child: const Text('Cancel campaign')));
        }
      case CampaignStatus.draft:
        buttons.add(FilledButton.icon(
          onPressed: () => context.go('/campaigns/$_id/edit'),
          icon: const Icon(Icons.edit),
          label: const Text('Continue editing'),
        ));
      case CampaignStatus.running:
        buttons.add(FilledButton.tonalIcon(
          onPressed: () async {
            // The sender checks the status before each message (works for the background service too).
            await ref.read(campaignRepositoryProvider).requestPause(_id);
            _refresh();
            _snack('Pausing after the current message.');
          },
          icon: const Icon(Icons.pause),
          label: const Text('Pause'),
        ));
        buttons.add(OutlinedButton(onPressed: _cancel, child: const Text('Cancel campaign')));
      case CampaignStatus.completed || CampaignStatus.partiallyCompleted || CampaignStatus.failed || CampaignStatus.cancelled:
        buttons.add(FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _sendAgain(c),
          icon: const Icon(Icons.replay),
          label: const Text('Send again'),
        ));
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
    final mixed = recipients.any((r) => r.isEmail) && recipients.any((r) => !r.isEmail);
    Widget chips(Iterable<CampaignRecipient> rs, {String? prefix}) {
      final counts = <RecipientStatus, int>{};
      for (final r in rs) {
        counts[r.status] = (counts[r.status] ?? 0) + 1;
      }
      return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (prefix != null) Text(prefix, style: const TextStyle(fontWeight: FontWeight.w700)),
        for (final s in RecipientStatus.values)
          if ((counts[s] ?? 0) > 0) Chip(label: Text('${recipientStatusLabel(s)}: ${counts[s]}')),
      ]);
    }
    if (!mixed) return chips(recipients);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      chips(recipients.where((r) => !r.isEmail), prefix: 'SMS'),
      const SizedBox(height: 6),
      chips(recipients.where((r) => r.isEmail), prefix: 'Email'),
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
      leading: Icon(r.isEmail ? Icons.email_outlined : Icons.sms_outlined, size: 20),
      minLeadingWidth: 20,
      title: Text(r.name),
      subtitle: Text(r.address),
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(r.name),
          content: Text('${r.isEmail ? 'Subject: ${r.subject ?? ''}\n\n' : ''}${r.renderedMessage}'
              '\n\nStatus: ${recipientStatusLabel(r.status)}'
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

/// The campaign's schedule, or a button to add one.
class _ScheduleSection extends ConsumerWidget {
  const _ScheduleSection({required this.campaign});
  final Campaign campaign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(campaignScheduleProvider(campaign.id)).valueOrNull;
    ScheduleRepository repo() => ref.read(scheduleRepositoryProvider);
    void refresh() => ref.read(dataVersionProvider.notifier).state++;
    if (s == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => context.push('/campaigns/${campaign.id}/schedule'),
          icon: const Icon(Icons.event_repeat),
          label: const Text('Schedule…'),
        ),
      );
    }
    final lines = <String>[
      describeSchedule(specOf(s)),
      if (!s.enabled) s.nextRunAt == null ? 'Finished' : 'Paused',
      if (s.enabled && s.nextRunAt != null) 'Next run: ${formatDateTime(s.nextRunAt!)}',
      if (s.lastOutcome != null && s.lastRunAt != null)
        'Last: ${scheduleOutcomeLabel(s.lastOutcome!)} (${formatDateTime(s.lastRunAt!)})',
    ];
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.event_repeat),
            const SizedBox(width: 8),
            Expanded(child: Text(lines.first, style: Theme.of(context).textTheme.titleSmall)),
          ]),
          for (final l in lines.skip(1)) Padding(padding: const EdgeInsets.only(top: 4), child: Text(l)),
          Wrap(spacing: 4, children: [
            TextButton(onPressed: () => context.push('/campaigns/${campaign.id}/schedule'), child: const Text('Edit')),
            if (s.enabled)
              TextButton(
                  onPressed: () async { await repo().setEnabled(s.id, false, now: DateTime.now()); refresh(); },
                  child: const Text('Pause'))
            else
              TextButton(
                  onPressed: () async { await repo().setEnabled(s.id, true, now: DateTime.now()); refresh(); },
                  child: const Text('Resume')),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Remove schedule?'),
                    content: const Text('No more runs will be sent. Past runs and their reports are kept.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                    ],
                  ),
                );
                if (ok == true) { await repo().delete(s.id); refresh(); }
              },
              child: const Text('Remove'),
            ),
          ]),
        ]),
      ),
    );
  }
}
