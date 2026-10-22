import 'dart:async';
import '../../data/repositories/attempt_repository.dart';
import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/send_settings.dart';
import '../../domain/services/send_limits.dart';
import '../../domain/models/statuses.dart';
import '../../platform/sms/sms_capability_service.dart';

/// One message handed to the Messages app, waiting for "Did you send it?".
class ManualSend {
  const ManualSend({required this.attemptId, required this.name, required this.phone, required this.body,
      required this.position, required this.total});
  final int attemptId;
  final String name, phone, body;
  /// 1-based position in the campaign, for "12 of 40".
  final int position, total;
}

class SendBlockedException implements Exception {
  SendBlockedException(this.blocker, [this.message]);
  final DirectSendBlocker blocker;
  final String? message;
  @override
  String toString() => message ?? 'Sending is blocked: ${blocker.name}';
}

/// Coordinates the persistent queue with the platform SMS service.
/// - Android: throttled automatic loop (`runAndroid`); results arrive via events.
/// - iOS: one composer per call (`sendNextViaComposer`); the user taps Send each time.
/// It never reports a result the platform didn't report.
class SendOrchestrator {
  SendOrchestrator({
    required this.sms, required this.attempts, required this.campaigns, this.settings,
    this.interval = const Duration(milliseconds: 1500),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final SmsCapabilityService sms;
  final AttemptRepository attempts;
  final CampaignRepository campaigns;
  /// Send delay and hourly/daily limits. Without it: [interval] and no limits.
  final SettingsRepository? settings;
  final Duration interval; // throttle between Android sends; avoids carrier burst limits
  final Future<void> Function(Duration) _sleep;

  StreamSubscription<SmsEvent>? _sub;
  Future<void> _chain = Future<void>.value();
  bool _active = false;
  bool _stop = false;

  /// Subscribe once at app start. Callbacks can arrive after a run loop has ended.
  void start() => _sub ??= sms.events.listen((e) => _chain = _chain.then((_) => _onEvent(e)));
  Future<void> dispose() async { await _sub?.cancel(); _sub = null; }
  /// Completes when all received events have been persisted (used by tests).
  Future<void> flushEvents() => _chain;

  Future<void> _onEvent(SmsEvent e) async {
    final next = switch (e.type) {
      'sendSucceeded' => RecipientStatus.sent,
      'sendFailed' => RecipientStatus.failed,
      'deliveryReported' => RecipientStatus.delivered,
      _ => null,
    };
    if (next == null) return;
    final cid = await attempts.applyResult(e.attemptId, next, errorCode: e.errorCode, errorMessage: e.errorMessage);
    if (cid != null) await attempts.finalizeCampaign(cid);
  }

  void pause() => _stop = true;

  Future<void> cancel(int campaignId) async {
    _stop = true;
    await attempts.cancelPending(campaignId);
    await campaigns.setStatus(campaignId, CampaignStatus.cancelled);
  }

  /// Sends a ready/paused campaign's pending recipients (Android). Returns the
  /// limit that paused it, if a send limit was reached (it then resumes by
  /// itself at [LimitHit.resumeAt]).
  Future<LimitHit?> runAndroid(int campaignId, {int? subscriptionId}) async {
    if (_active) throw StateError('A campaign is already being sent.');
    final campaign = await campaigns.get(campaignId);
    if (campaign == null) throw StateError('Campaign not found.');
    if (campaign.status != CampaignStatus.ready && campaign.status != CampaignStatus.paused) {
      throw StateError('Campaign is ${campaign.status.name}; it must be confirmed (ready) or paused to send.');
    }
    final caps = await sms.getCapabilities();
    if (caps.platform != SmsPlatform.android) throw StateError('runAndroid is Android-only.');
    if (!caps.canSendDirectly) throw SendBlockedException(caps.blocker, caps.messageForUser);

    final cfg = await settings?.load();
    // Refuse to start (or resume) while a limit still applies.
    final startHit = await _limitHit(cfg);
    if (startHit != null) {
      // Wait for the limit and resume by itself (also when you tapped Resume).
      await attempts.markRunning(campaignId);
      await campaigns.pauseForLimit(campaignId, startHit.kind, startHit.resumeAt);
      return startHit;
    }

    _active = true; _stop = false;
    var halted = false;
    LimitHit? hit;
    try {
      await attempts.markRunning(campaignId);
      var stoppedElsewhere = false;
      while (!_stop) {
        // Pause/cancel may come from another engine (the app screen while the
        // background service sends): the database status is the signal.
        final now = await campaigns.get(campaignId);
        if (now == null || now.status != CampaignStatus.running) { stoppedElsewhere = true; break; }
        final r = await attempts.nextPending(campaignId);
        if (r == null) break;
        hit = await _limitHit(cfg);
        if (hit != null) {
          await campaigns.pauseForLimit(campaignId, hit.kind, hit.resumeAt);
          stoppedElsewhere = true; // status set: don't overwrite it below
          break;
        }
        final int attemptId;
        try {
          attemptId = await attempts.beginAttempt(r.id, 'android');
        } on AttemptRefusedException {
          continue; // e.g. cancelled between nextPending and here: never send it
        }
        // Persist "submitted" BEFORE invoking native code: a crash now yields `unknown`, not a duplicate.
        await attempts.applyResult(attemptId, RecipientStatus.submitted);
        final res = await sms.sendMessage(SmsSendRequest(
            campaignRecipientId: r.id, attemptId: attemptId, phoneE164: r.phone,
            body: r.renderedMessage, subscriptionId: subscriptionId ?? campaign.subscriptionId));
        if (res.storedMessageId != null) await attempts.linkStoredMessage(attemptId, res.storedMessageId!);
        if (res.status == RecipientStatus.failed) {
          await attempts.applyResult(attemptId, RecipientStatus.failed,
              errorCode: res.errorCode, errorMessage: res.errorMessage);
          // Never silently switch SIM or push on without permission.
          if (res.errorCode == 'subscription_unavailable' || res.errorCode == 'permission_denied') {
            halted = true; break;
          }
        }
        if (!_stop) await _sleep(cfg?.delay ?? interval);
      }
      if (stoppedElsewhere) {
        // Paused or cancelled by the user: leave the status they chose.
      } else if (_stop || halted) {
        final cur = await campaigns.get(campaignId);
        if (cur?.status == CampaignStatus.running) await campaigns.setStatus(campaignId, CampaignStatus.paused);
      } else {
        await attempts.finalizeCampaign(campaignId); // stays running until in-flight callbacks arrive
      }
    } finally {
      _active = false;
    }
    return hit;
  }

  /// The limit reached right now, if any.
  Future<LimitHit?> _limitHit(SendSettings? cfg) async {
    if (cfg == null || (cfg.hourlyLimit <= 0 && cfg.dailyLimit <= 0)) return null;
    final now = DateTime.now();
    return checkLimits(
        sent: await attempts.sendTimesSince(now.subtract(const Duration(hours: 24))), now: now, settings: cfg);
  }

  /// iOS: presents one composer. Returns the recipient's resulting status, or null if nothing is pending.
  /// A cancelled composer is recorded as `cancelled`, never `sent`. The campaign stays
  /// `awaitingUserAction` until every recipient is settled.
  Future<RecipientStatus?> sendNextViaComposer(int campaignId) async {
    if (_active) throw StateError('A composer is already open.');
    final campaign = await campaigns.get(campaignId);
    if (campaign == null) throw StateError('Campaign not found.');
    if (campaign.status == CampaignStatus.draft || campaign.status == CampaignStatus.cancelled) {
      throw StateError('Campaign is ${campaign.status.name}; confirm it first.');
    }
    final caps = await sms.getCapabilities();
    if (caps.platform != SmsPlatform.ios || !caps.usesComposerHandoff) {
      throw SendBlockedException(caps.blocker, caps.messageForUser ?? 'The message composer is unavailable.');
    }
    _active = true;
    try {
      final r = await attempts.nextPending(campaignId);
      if (r == null) { await attempts.finalizeCampaign(campaignId); return null; }
      await campaigns.setStatus(campaignId, CampaignStatus.awaitingUserAction);
      final attemptId = await attempts.beginAttempt(r.id, 'ios');
      await attempts.applyResult(attemptId, RecipientStatus.awaitingUserAction);
      final res = await sms.sendMessage(SmsSendRequest(
          campaignRecipientId: r.id, attemptId: attemptId, phoneE164: r.phone, body: r.renderedMessage));
      await attempts.applyResult(attemptId, res.status, errorCode: res.errorCode, errorMessage: res.errorMessage);
      await attempts.finalizeCampaign(campaignId);
      return res.status;
    } finally {
      _active = false;
    }
  }

  /// Messages-app fallback (Android without direct sending): prepares the next
  /// pending recipient and returns what to open, or null if none is left. The
  /// campaign waits on the user until [finishManualSend] records the answer.
  Future<ManualSend?> startManualSend(int campaignId) async {
    final campaign = await campaigns.get(campaignId);
    if (campaign == null) throw StateError('Campaign not found.');
    if (campaign.status == CampaignStatus.draft || campaign.status == CampaignStatus.cancelled ||
        campaign.status == CampaignStatus.running) {
      throw StateError('Campaign is ${campaign.status.name}; it can\'t be sent from the Messages app now.');
    }
    final r = await attempts.nextPending(campaignId);
    if (r == null) {
      await attempts.finalizeCampaign(campaignId);
      return null;
    }
    await campaigns.setStatus(campaignId, CampaignStatus.awaitingUserAction);
    final attemptId = await attempts.beginAttempt(r.id, 'android_manual');
    await attempts.applyResult(attemptId, RecipientStatus.awaitingUserAction);
    final counts = await campaigns.statusCounts(campaignId);
    final left = (counts[RecipientStatus.pending] ?? 0);
    return ManualSend(attemptId: attemptId, name: r.name, phone: r.phone, body: r.renderedMessage,
        position: campaign.recipientCount - left, total: campaign.recipientCount);
  }

  /// The user's answer: [sent] true -> `sent` (confirmed by the user, not the
  /// carrier); false -> `cancelled` (can be sent again later).
  Future<void> finishManualSend(int attemptId, {required bool sent, String? errorCode}) async {
    final cid = await attempts.applyResult(attemptId, sent ? RecipientStatus.sent : RecipientStatus.cancelled,
        errorCode: errorCode ?? (sent ? 'user_confirmed' : null));
    if (cid != null) await attempts.finalizeCampaign(cid);
  }
}
