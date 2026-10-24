import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repositories/attempt_repository.dart';
import '../features/sms_sending/send_orchestrator.dart';
import '../features/setup/setup_status.dart';
import '../platform/background/background_send_service.dart';
import '../domain/models/email_settings.dart';
import '../platform/email/email_sender.dart';
import '../platform/email/email_senders.dart';
import '../platform/email/google_gmail_auth.dart';
import '../platform/messages/messages_service.dart';
import '../platform/reminders/schedule_reminders.dart';
import '../platform/sms/android_sms_service.dart';
import '../platform/sms/ios_sms_service.dart';
import '../platform/sms/messages_app.dart';
import '../platform/sms/sms_capability_service.dart';
import 'providers.dart';

final attemptRepositoryProvider = Provider((ref) => AttemptRepository(ref.watch(databaseProvider)));

final smsServiceProvider = Provider<SmsCapabilityService>(
    (ref) => Platform.isIOS ? IosSmsService() : AndroidSmsService());

/// Call `attemptRepositoryProvider.recoverInterrupted()` once at startup
/// before reading this.
final gmailAuthProvider = Provider<GoogleGmailAuth>((ref) => GoogleGmailAuth());

/// The HTTP call email senders use; null = the real one (tests override it).
final emailPostProvider = Provider<HttpPost?>((ref) => null);

/// The email sender for [settings], or null when email is off.
final emailSenderFactoryProvider = Provider<EmailSender? Function(EmailSettings)>((ref) {
  final gmail = ref.watch(gmailAuthProvider);
  final post = ref.watch(emailPostProvider);
  return (s) => emailSenderFor(s, gmail: gmail, post: post);
});

final sendOrchestratorProvider = Provider((ref) {
  final settings = ref.watch(settingsRepositoryProvider);
  final senderFor = ref.watch(emailSenderFactoryProvider);
  final o = SendOrchestrator(
    sms: ref.watch(smsServiceProvider),
    attempts: ref.watch(attemptRepositoryProvider),
    campaigns: ref.watch(campaignRepositoryProvider),
    settings: settings,
    emailSender: () async => senderFor(await settings.loadEmail()),
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

/// What's granted and what's missing (Android). Null where not applicable
/// (iOS has no required items until reminders arrive).
final setupStatusProvider = FutureProvider<SetupStatus?>((ref) async {
  final b = await ref.watch(backgroundStatusProvider.future);
  return b == null ? null : SetupStatus.fromAndroid(b);
});

/// iPhone / iPad: local reminders when a scheduled campaign is due. Null on Android (it sends in the background).
final scheduleRemindersProvider = Provider<ScheduleReminders?>((ref) => Platform.isIOS ? IosScheduleReminders() : null);

/// Android: opens the default Messages app (fallback when direct sending isn't allowed).
final messagesAppProvider = Provider<MessagesApp?>((ref) => Platform.isAndroid ? NativeMessagesApp() : null);

/// Android: the phone's messages (inbox) while this is the default messaging app. Null elsewhere.
final messagesServiceProvider = Provider<MessagesService?>((ref) => Platform.isAndroid ? NativeMessagesService() : null);

/// Bumped when messages change (a text arrived, a status updated, opened a conversation).
final messagesVersionProvider = StateProvider<int>((ref) => 0);

final isDefaultSmsProvider = FutureProvider<bool>((ref) async {
  ref.watch(messagesVersionProvider);
  ref.watch(backgroundStatusVersionProvider);
  return await ref.watch(messagesServiceProvider)?.isDefault() ?? false;
});

final conversationsProvider = FutureProvider<List<ConversationSummary>>((ref) async {
  ref.watch(messagesVersionProvider);
  final svc = ref.watch(messagesServiceProvider);
  if (svc == null || !await ref.watch(isDefaultSmsProvider.future)) return const [];
  return svc.conversations();
});

final threadMessagesProvider = FutureProvider.family<List<StoredMessage>, int>((ref, threadId) async {
  ref.watch(messagesVersionProvider);
  return await ref.watch(messagesServiceProvider)?.messages(threadId) ?? const [];
});
