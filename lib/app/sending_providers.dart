import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repositories/attempt_repository.dart';
import '../features/sms_sending/send_orchestrator.dart';
import '../platform/background/background_send_service.dart';
import '../platform/sms/android_sms_service.dart';
import '../platform/sms/ios_sms_service.dart';
import '../platform/sms/sms_capability_service.dart';
import 'providers.dart';

final attemptRepositoryProvider = Provider((ref) => AttemptRepository(ref.watch(databaseProvider)));

final smsServiceProvider = Provider<SmsCapabilityService>(
    (ref) => Platform.isIOS ? IosSmsService() : AndroidSmsService());

/// Call `attemptRepositoryProvider.recoverInterrupted()` once at startup
/// before reading this.
final sendOrchestratorProvider = Provider((ref) {
  final o = SendOrchestrator(
    sms: ref.watch(smsServiceProvider),
    attempts: ref.watch(attemptRepositoryProvider),
    campaigns: ref.watch(campaignRepositoryProvider),
  )..start();
  ref.onDispose(o.dispose);
  return o;
});

/// Android only: the foreground service that does all Android sending (manual
/// and scheduled) so it continues with the app closed. Null elsewhere.
final backgroundSendServiceProvider = Provider<BackgroundSendService?>(
    (ref) => Platform.isAndroid ? NativeBackgroundSendService() : null);

/// Bump to re-read [backgroundStatusProvider] (e.g. on returning from Settings).
final backgroundStatusVersionProvider = StateProvider<int>((ref) => 0);

final backgroundStatusProvider = FutureProvider<BackgroundStatus?>((ref) async {
  ref.watch(backgroundStatusVersionProvider);
  final bg = ref.watch(backgroundSendServiceProvider);
  return bg?.status();
});
