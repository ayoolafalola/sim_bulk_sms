import 'dart:async';
import '../../data/repositories/attempt_repository.dart';
import '../../data/repositories/campaign_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../domain/models/campaign.dart';
import '../../domain/models/channels.dart';
import '../../domain/models/email_settings.dart';
import '../../domain/models/pro.dart';
import '../../domain/models/send_settings.dart';
import '../../domain/services/email_body.dart';
import '../../platform/email/email_sender.dart';
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

/// A batch of recipients who get the same text, handed to the Messages app in one go.
class ManualBatch {
  const ManualBatch({required this.attemptIds, required this.names, required this.phones, required this.body,
      required this.from, required this.total});
  final List<int> attemptIds;
  final List<String> names, phones;
  final String body;
  /// 1-based position of the batch's first recipient among the campaign's texts, for "21–40 of 95".
  final int from, total;
  int get to => from + phones.length - 1;
}

class SendBlockedException implements Exception {
  SendBlockedException(this.blocker, [this.message]);
  final DirectSendBlocker blocker;
  final String? message;
  @override
  String toString() => message ?? 'Sending is blocked: ${blocker.name}';
}

/// Coordinates the persistent queue with the platform SMS service and the email sender.
/// - Android: throttled automatic loop (`runAndroid`) for texts and emails; SMS results arrive via events.
/// - Emails only (`runEmails`): wherever texts need the user (iOS, Messages-app fallback).
/// - iOS: one composer per call (`sendNextViaComposer`); the user taps Send each time.
/// It never reports a result the platform or email service didn't report.
class SendOrchestrator {
  SendOrchestrator({
    required this.sms, required this.attempts, required this.campaigns, this.settings, this.emailSender,
    this.interval = const Duration(milliseconds: 1500),
    this.emailInterval = const Duration(milliseconds: 500),
    Future<void> Function(Duration)? sleep,
  }) : _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final SmsCapabilityService sms;
  final AttemptRepository attempts;
  final CampaignRepository campaigns;
  /// Send delay and hourly/daily limits. Without it: [interval] and no limits.
  final SettingsRepository? settings;
  final Duration interval; // throttle between Android sends; avoids carrier burst limits
  final Duration emailInterval;
  /// Builds the email sender from the current email settings (null when email is off).
  final Future<EmailSender?> Function()? emailSender;
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

  /// Sends a ready/paused campaign's pending texts (Android) and emails. Returns
  /// the limit that paused it, if a send limit was reached (it then resumes by
  /// itself at [LimitHit.resumeAt]).
  Future<LimitHit?> runAndroid(int campaignId, {int? subscriptionId}) =>
      _runAutomatic(campaignId, subscriptionId: subscriptionId);

  /// Sends only the pending emails, where texts need the user (iOS, or Android
  /// without direct sending). Texts stay pending; the campaign then waits for you.
  Future<LimitHit?> runEmails(int campaignId) => _runAutomatic(campaignId, emailsOnly: true);

  Future<LimitHit?> _runAutomatic(int campaignId, {int? subscriptionId, bool emailsOnly = false}) async {
    if (_active) throw StateError('A campaign is already being sent.');
    final campaign = await campaigns.get(campaignId);
    if (campaign == null) throw StateError('Campaign not found.');
    final startable = {CampaignStatus.ready, CampaignStatus.paused, if (emailsOnly) CampaignStatus.awaitingUserAction};
    if (!startable.contains(campaign.status)) {
      throw StateError('Campaign is ${campaign.status.name}; it must be confirmed (ready) or paused to send.');
    }
    final pending = await campaigns.pendingByChannel(campaignId);
    final doSms = !emailsOnly && pending.sms > 0;
    if (doSms) {
      final caps = await sms.getCapabilities();
      if (caps.platform != SmsPlatform.android) throw StateError('runAndroid is Android-only.');
      if (!caps.canSendDirectly) throw SendBlockedException(caps.blocker, caps.messageForUser);
    }
    EmailSender? mailer;
    if (pending.email > 0) {
      mailer = await emailSender?.call();
      if (mailer == null) throw EmailNotReadyException('Set up email in Settings › Email first.');
      await mailer.prepare();
    }
    if (!doSms && pending.email == 0) return null;

    final cfg = await settings?.load();
    final emailCfg = await settings?.loadEmail() ?? const EmailSettings();
    final signature = await _signature();
    final pro = await settings?.loadPro() ?? const ProStatus();
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
        final r = await attempts.nextPending(campaignId, channel: doSms ? null : MessageChannel.email);
        if (r == null) break;
        hit = r.isEmail ? await _emailLimitHit(emailCfg, pro) : await _limitHit(cfg);
        if (hit != null) {
          await campaigns.pauseForLimit(campaignId, hit.kind, hit.resumeAt, email: hit.email);
          stoppedElsewhere = true; // status set: don't overwrite it below
          break;
        }
        final int attemptId;
        try {
          attemptId = await attempts.beginAttempt(r.id, r.isEmail ? 'email' : 'android');
        } on AttemptRefusedException {
          continue; // e.g. cancelled between nextPending and here: never send it
        }
        // Persist "submitted" BEFORE sending: a crash now yields `unknown`, not a duplicate.
        await attempts.applyResult(attemptId, RecipientStatus.submitted);
        if (r.isEmail) {
          halted = !await _sendEmail(mailer!, emailCfg, campaign, r, attemptId, signature);
          if (halted) break;
          if (!_stop) await _sleep(emailInterval);
          continue;
        }
        final body = withSignature(r.renderedMessage, signature);
        await attempts.setSentBody(attemptId, body);
        final res = await sms.sendMessage(SmsSendRequest(
            campaignRecipientId: r.id, attemptId: attemptId, phoneE164: r.phone,
            body: body, subscriptionId: subscriptionId ?? campaign.subscriptionId));
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
        // Paused or cancelled by the user, or waiting on a limit: leave that status.
      } else if (_stop || halted) {
        final cur = await campaigns.get(campaignId);
        if (cur?.status == CampaignStatus.running) await campaigns.setStatus(campaignId, CampaignStatus.paused);
      } else if (emailsOnly && (await campaigns.pendingByChannel(campaignId)).sms > 0) {
        await campaigns.setStatus(campaignId, CampaignStatus.awaitingUserAction); // the texts are up to you
      } else {
        await attempts.finalizeCampaign(campaignId); // stays running until in-flight callbacks arrive
      }
    } finally {
      _active = false;
    }
    return hit;
  }

  /// Sends one email row and records the outcome. Returns false when sending
  /// should stop (the service refused the login or address: every email would fail).
  Future<bool> _sendEmail(
      EmailSender mailer, EmailSettings cfg, Campaign c, CampaignRecipient r, int attemptId, String? signature) async {
    final body = emailBodies(r.renderedMessage, cfg, signature: signature);
    await attempts.setSentBody(attemptId, body.text);
    final res = await mailer.send(OutgoingEmail(
      id: 'cr-${r.id}-a$attemptId', campaignId: c.id, toAddress: r.email ?? '', toName: r.name,
      subject: r.subject ?? c.name, text: body.text, html: body.html,
    ));
    if (res.providerId != null) await attempts.setOperationId(attemptId, res.providerId!);
    final next = switch (res.outcome) {
      EmailOutcome.sent => RecipientStatus.sent,
      EmailOutcome.failed => RecipientStatus.failed,
      EmailOutcome.unknown => RecipientStatus.unknown,
    };
    await attempts.applyResult(attemptId, next, errorCode: res.errorCode, errorMessage: res.errorMessage);
    return !const {'auth', 'not_found', 'gmail_auth'}.contains(res.errorCode);
  }

  /// The campaign signature right now (none without settings, e.g. in some tests).
  Future<String?> _signature() async => await settings?.signature();

  /// The email limit reached right now, if any. The free app allows [FreeLimits.emailsPerDay] a day.
  Future<LimitHit?> _emailLimitHit(EmailSettings cfg, ProStatus pro) async {
    var daily = cfg.dailyLimit;
    if (!pro.has(ProFeature.unlimitedEmail)) {
      daily = daily <= 0 ? FreeLimits.emailsPerDay : daily.clamp(0, FreeLimits.emailsPerDay);
    }
    if (cfg.hourlyLimit <= 0 && daily <= 0) return null;
    final now = DateTime.now();
    final h = checkLimits(
        sent: await attempts.emailSendTimesSince(now.subtract(const Duration(hours: 24))), now: now,
        settings: SendSettings(hourlyLimit: cfg.hourlyLimit, dailyLimit: daily));
    return h == null ? null : LimitHit(h.kind, h.resumeAt, email: true);
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
      final r = await attempts.nextPending(campaignId, channel: MessageChannel.sms);
      if (r == null) { await attempts.finalizeCampaign(campaignId); return null; }
      await campaigns.setStatus(campaignId, CampaignStatus.awaitingUserAction);
      final attemptId = await attempts.beginAttempt(r.id, 'ios');
      await attempts.applyResult(attemptId, RecipientStatus.awaitingUserAction);
      final body = withSignature(r.renderedMessage, await _signature());
      await attempts.setSentBody(attemptId, body);
      final res = await sms.sendMessage(SmsSendRequest(
          campaignRecipientId: r.id, attemptId: attemptId, phoneE164: r.phone, body: body));
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
    final r = await attempts.nextPending(campaignId, channel: MessageChannel.sms);
    if (r == null) {
      await attempts.finalizeCampaign(campaignId);
      return null;
    }
    await campaigns.setStatus(campaignId, CampaignStatus.awaitingUserAction);
    final attemptId = await attempts.beginAttempt(r.id, 'android_manual');
    await attempts.applyResult(attemptId, RecipientStatus.awaitingUserAction);
    final texts = (await campaigns.recipients(campaignId)).where((x) => !x.isEmail).toList();
    final left = texts.where((x) => x.status == RecipientStatus.pending).length;
    final body = withSignature(r.renderedMessage, await _signature());
    await attempts.setSentBody(attemptId, body);
    return ManualSend(attemptId: attemptId, name: r.name, phone: r.phone, body: body,
        position: texts.length - left, total: texts.length);
  }

  /// Whether the pending texts are all the same (no per-person placeholders), so they can
  /// go to several people in one message.
  Future<bool> canBatch(int campaignId) async {
    final texts = (await campaigns.recipients(campaignId))
        .where((r) => !r.isEmail && r.status == RecipientStatus.pending).map((r) => r.renderedMessage).toSet();
    return texts.length == 1;
  }

  /// Messages-app fallback, all at once: prepares up to [size] pending recipients that get
  /// the same text, or null if none is left. Answer with [finishManualBatch].
  Future<ManualBatch?> startManualBatch(int campaignId, {int size = 20}) async {
    final campaign = await campaigns.get(campaignId);
    if (campaign == null) throw StateError('Campaign not found.');
    if (campaign.status == CampaignStatus.draft || campaign.status == CampaignStatus.cancelled ||
        campaign.status == CampaignStatus.running) {
      throw StateError('Campaign is ${campaign.status.name}; it can\'t be sent from the Messages app now.');
    }
    final texts = (await campaigns.recipients(campaignId)).where((r) => !r.isEmail).toList();
    final pending = texts.where((r) => r.status == RecipientStatus.pending).toList();
    if (pending.isEmpty) {
      await attempts.finalizeCampaign(campaignId);
      return null;
    }
    final text = pending.first.renderedMessage;
    final batch = pending.where((r) => r.renderedMessage == text).take(size).toList();
    await campaigns.setStatus(campaignId, CampaignStatus.awaitingUserAction);
    final body = withSignature(text, await _signature());
    final ids = <int>[];
    for (final r in batch) {
      final id = await attempts.beginAttempt(r.id, 'android_manual');
      await attempts.applyResult(id, RecipientStatus.awaitingUserAction);
      await attempts.setSentBody(id, body);
      ids.add(id);
    }
    final from = texts.length - pending.length + 1;
    return ManualBatch(attemptIds: ids, names: [for (final r in batch) r.name], phones: [for (final r in batch) r.phone],
        body: body, from: from, total: texts.length);
  }

  /// The user's answer for a whole batch (see [finishManualSend]).
  Future<void> finishManualBatch(List<int> attemptIds, {required bool sent, String? errorCode}) async {
    int? cid;
    for (final id in attemptIds) {
      cid = await attempts.applyResult(id, sent ? RecipientStatus.sent : RecipientStatus.cancelled,
          errorCode: errorCode ?? (sent ? 'user_confirmed' : null)) ?? cid;
    }
    if (cid != null) await attempts.finalizeCampaign(cid);
  }

  /// The user's answer: [sent] true -> `sent` (confirmed by the user, not the
  /// carrier); false -> `cancelled` (can be sent again later).
  Future<void> finishManualSend(int attemptId, {required bool sent, String? errorCode}) async {
    final cid = await attempts.applyResult(attemptId, sent ? RecipientStatus.sent : RecipientStatus.cancelled,
        errorCode: errorCode ?? (sent ? 'user_confirmed' : null));
    if (cid != null) await attempts.finalizeCampaign(cid);
  }
}
