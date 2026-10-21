import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repositories/attempt_repository.dart';
import '../features/sms_sending/send_orchestrator.dart';
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
