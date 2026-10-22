import 'dart:async';
import '../data/repositories/campaign_repository.dart';
import '../data/repositories/schedule_repository.dart';
import '../domain/models/channels.dart';
import '../domain/models/schedule.dart';
import '../domain/models/statuses.dart';
import '../features/campaigns/campaign_labels.dart';
import '../domain/services/send_limits.dart';
import '../features/scheduling/next_wake.dart';
import '../features/scheduling/schedule_runner.dart';
import '../features/sms_sending/send_orchestrator.dart';
import '../platform/email/email_sender.dart';
import '../platform/sms/sms_capability_service.dart';
import 'background_host.dart';

/// How long the service waits after the last message for sent/delivery
/// callbacks before stopping. Later delivery reports are not recorded.
const deliveryWait = Duration(minutes: 2);

/// What the Android foreground service does with its queue: send requested
/// campaigns and due scheduled runs one at a time (never two at once), report
/// progress and results as notifications, set the next wake-up, then finish.
class BackgroundJob {
  BackgroundJob({
    required this.host, required this.sms, required this.orchestrator, required this.runner,
    required this.campaigns, required this.schedules,
    DateTime Function()? clock, Future<void> Function(Duration)? sleep,
    this.pollEvery = const Duration(seconds: 2), this.waitForCallbacks = deliveryWait,
  })  : _clock = clock ?? DateTime.now,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d));

  final BackgroundHost host;
  final SmsCapabilityService sms;
  final SendOrchestrator orchestrator;
  final ScheduleRunner runner;
  final CampaignRepository campaigns;
  final ScheduleRepository schedules;
  final Duration pollEvery, waitForCallbacks;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _sleep;

  Future<void> run() async {
    while (true) {
      final job = await host.takeJob();
      if (job != null) {
        try {
          if (job.campaignId != null) await _send(job.campaignId!, subscriptionId: job.subscriptionId);
          await _runDueSchedules();
        } catch (e) {
          await host.notifyResult('Background sending stopped', '$e');
        }
        continue;
      }
      await host.scheduleWake(await nextWakeUp(schedules, campaigns));
      if (await host.finish()) return;
    }
  }

  Future<void> _runDueSchedules() async {
    // Campaigns paused at a send limit whose resume time has come.
    for (final id in await campaigns.dueResumes(_clock())) {
      await _send(id);
    }
    // One run at a time; keep going while runs are due (bounded for safety).
    for (var i = 0; i < 20; i++) {
      bool canAuto;
      try {
        canAuto = (await sms.getCapabilities()).canSendDirectly;
      } catch (_) {
        canAuto = false;
      }
      final results = await runner.runDue(_clock(), platform: 'android', canAutoSend: canAuto);
      var sent = false;
      for (final r in results) {
        final name = r.campaignName ?? 'Scheduled campaign';
        if (r.outcome == ScheduleOutcome.started && r.campaignId != null) {
          await _send(r.campaignId!);
          sent = true;
        } else {
          if (r.outcome == ScheduleOutcome.needsAttention && r.campaignId != null) {
            // Texts wait for you, but its emails can go now.
            try {
              await orchestrator.runEmails(r.campaignId!);
            } catch (_) {/* email not set up or not needed: the reminder below still says what to do */}
          }
          await host.notifyResult(name, scheduleOutcomeLabel(r.outcome));
        }
      }
      if (!sent) return;
    }
  }

  Future<void> _send(int campaignId, {int? subscriptionId}) async {
    final c = await campaigns.get(campaignId);
    if (c == null) return;
    final title = 'Sending ${c.name}';
    await host.progress(title: title, text: 'Starting…', total: c.recipientCount);
    final ticker = Timer.periodic(const Duration(seconds: 3), (_) async {
      final n = await campaigns.statusCounts(campaignId);
      final done = c.recipientCount - (n[RecipientStatus.pending] ?? 0);
      await host.progress(title: title, text: '$done of ${c.recipientCount}', done: done, total: c.recipientCount);
    });
    LimitHit? hit;
    try {
      hit = await orchestrator.runAndroid(campaignId, subscriptionId: subscriptionId);
    } on SendBlockedException catch (e) {
      await host.notifyResult('${c.name} was not sent', e.toString());
      return;
    } on StateError catch (e) {
      await host.notifyResult('${c.name} was not sent', e.message);
      return;
    } on EmailNotReadyException catch (e) {
      await host.notifyResult('${c.name} was not sent', e.message);
      return;
    } finally {
      ticker.cancel();
    }
    await host.progress(title: title, text: 'Waiting for delivery reports…', done: c.recipientCount, total: c.recipientCount);
    await _awaitCallbacks(campaignId);
    final limit = hit == null
        ? ''
        : '${limitLabel(hit.kind, email: hit.email)} reached. Resumes automatically at ${formatWhen(hit.resumeAt, now: _clock())}. ';
    await host.notifyResult(
        await _resultTitle(campaignId, c.name), '$limit${_summary(await campaigns.statusCounts(campaignId))}');
  }

  /// Until every message has a sent/failed result and (if the carrier sends
  /// them) delivery reports, or [waitForCallbacks] has passed.
  Future<void> _awaitCallbacks(int campaignId) async {
    final deadline = _clock().add(waitForCallbacks);
    while (true) {
      // Texts only: emails get no delivery reports.
      final n = await campaigns.statusCounts(campaignId, channel: MessageChannel.sms);
      final waiting = (n[RecipientStatus.submitted] ?? 0) + (n[RecipientStatus.sent] ?? 0);
      if (waiting == 0 || !_clock().isBefore(deadline)) return;
      await _sleep(pollEvery);
    }
  }

  Future<String> _resultTitle(int campaignId, String name) async {
    final s = (await campaigns.get(campaignId))?.status;
    return switch (s) {
      CampaignStatus.paused => '$name paused',
      CampaignStatus.cancelled => '$name cancelled',
      _ => '$name finished',
    };
  }

  static String _summary(Map<RecipientStatus, int> n) {
    final parts = <String>[
      for (final s in const [
        RecipientStatus.delivered, RecipientStatus.sent, RecipientStatus.submitted, RecipientStatus.failed,
        RecipientStatus.unknown, RecipientStatus.cancelled, RecipientStatus.pending,
      ])
        if ((n[s] ?? 0) > 0) '${n[s]} ${recipientStatusLabel(s).toLowerCase()}',
    ];
    return parts.isEmpty ? 'Nothing to send.' : parts.join(', ');
  }
}
