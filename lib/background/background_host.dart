import 'package:flutter/services.dart';

/// A request queued with the service: send one campaign, or just check schedules.
class BackgroundJobRequest {
  const BackgroundJobRequest.send(int this.campaignId, {this.subscriptionId});
  const BackgroundJobRequest.check() : campaignId = null, subscriptionId = null;
  final int? campaignId;
  final int? subscriptionId;
}

/// Service-side link to the Android foreground service hosting this engine.
abstract class BackgroundHost {
  /// Next queued request, or null when the queue is empty.
  Future<BackgroundJobRequest?> takeJob();
  Future<void> progress({required String title, String? text, int done = 0, int total = 0});
  Future<void> notifyResult(String title, String text);
  Future<bool> scheduleWake(DateTime? at);
  /// Stops the service if nothing new was queued; returns false otherwise.
  Future<bool> finish();
}

class NativeBackgroundHost implements BackgroundHost {
  static const _ch = MethodChannel('app.sim_bulk_sms/background_service');

  @override
  Future<BackgroundJobRequest?> takeJob() async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('takeJob');
    if (m == null) return null;
    final id = m['campaignId'] as int?;
    return id == null
        ? const BackgroundJobRequest.check()
        : BackgroundJobRequest.send(id, subscriptionId: m['subscriptionId'] as int?);
  }

  @override
  Future<void> progress({required String title, String? text, int done = 0, int total = 0}) =>
      _ch.invokeMethod('progress', {'title': title, 'text': text, 'done': done, 'total': total});

  @override
  Future<void> notifyResult(String title, String text) =>
      _ch.invokeMethod('notifyResult', {'title': title, 'text': text});

  @override
  Future<bool> scheduleWake(DateTime? at) async =>
      await _ch.invokeMethod<bool>('scheduleWake', {'at': at?.millisecondsSinceEpoch}) ?? false;

  @override
  Future<bool> finish() async => await _ch.invokeMethod<bool>('finish') ?? true;
}
