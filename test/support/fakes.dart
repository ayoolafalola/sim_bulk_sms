import 'dart:async';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/platform/contacts/phone_contacts_service.dart';
import 'package:sim_bulk_sms/platform/background/background_send_service.dart';
import 'package:sim_bulk_sms/platform/messages/messages_service.dart';
import 'package:sim_bulk_sms/platform/sms/messages_app.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';

/// Background/setup bridge with a mutable permission state.
class FakeBackground implements BackgroundSendService {
  FakeBackground(this.current);
  BackgroundStatus current;
  final opened = <String>[];
  @override Future<bool> startSend(int campaignId, {int? subscriptionId}) async => true;
  @override Future<bool> checkNow() async => true;
  @override Future<bool> scheduleWake(DateTime? at) async => current.exactAlarms;
  @override Future<BackgroundStatus> status() async => current;
  @override
  Future<bool> requestNotifications() async {
    current = copy(current, notifications: true);
    return true;
  }
  @override Future<void> openNotificationSettings() async => opened.add('notifications');
  @override Future<void> openExactAlarmSettings() async => opened.add('alarms');
  @override Future<void> openBatterySettings() async => opened.add('battery');
  @override Future<void> openAppSettings() async => opened.add('app');

  static BackgroundStatus copy(BackgroundStatus s, {bool? sms, bool? notifications, bool? defaultSms}) => BackgroundStatus(
        notifications: notifications ?? s.notifications, exactAlarms: s.exactAlarms,
        batteryUnrestricted: s.batteryUnrestricted, serviceRunning: s.serviceRunning, telephony: s.telephony,
        sms: sms ?? s.sms, smsPermanentlyDenied: s.smsPermanentlyDenied, contacts: s.contacts,
        contactsPermanentlyDenied: s.contactsPermanentlyDenied, defaultSms: defaultSms ?? s.defaultSms,
      );
}

const nothingGranted = BackgroundStatus(
    notifications: false, exactAlarms: false, batteryUnrestricted: false, serviceRunning: false,
    sms: false, contacts: false, defaultSms: false);
const everythingGranted = BackgroundStatus(
    notifications: true, exactAlarms: true, batteryUnrestricted: true, serviceRunning: false,
    sms: true, contacts: true, defaultSms: true);

/// SMS service whose permission prompt grants SMS in [bg].
class FakeSmsService implements SmsCapabilityService {
  FakeSmsService(this.caps, {this.bg, this.sims = const []});
  SmsCapabilities caps;
  final List<SimSubscription> sims;
  final FakeBackground? bg;
  final controller = StreamController<SmsEvent>.broadcast();
  @override Future<SmsCapabilities> getCapabilities() async => caps;
  @override
  Future<bool> requestRequiredPermissions() async {
    if (bg != null) bg!.current = FakeBackground.copy(bg!.current, sms: true);
    return true;
  }
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => sims;
  @override Stream<SmsEvent> get events => controller.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async => const SmsOperationResult(RecipientStatus.submitted);
}

class FakeMessagesApp implements MessagesApp {
  FakeMessagesApp({this.available = true});
  final bool available;
  final opened = <(String, String)>[];
  @override
  Future<bool> open(String phone, String body) async {
    if (available) opened.add((phone, body));
    return available;
  }
  @override
  Future<bool> openMany(List<String> phones, String body) async {
    if (available) opened.add((phones.join(','), body));
    return available;
  }
}

const androidFallback = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false,
    usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.permissionDenied,
    messageForUser: 'SMS permission is off. Messages open in your Messages app instead, one tap each.');

/// The phone's message store, in memory. Becoming default flips [bg]'s status too.
class FakeMessagesService implements MessagesService {
  FakeMessagesService({this.isDefaultApp = true, this.bg, this.grantOnRequest = true});
  bool isDefaultApp;
  final FakeBackground? bg;
  final bool grantOnRequest;
  final threads = <int, List<StoredMessage>>{};
  final names = <int, String>{};
  final readThreads = <int>[];
  final sent = <(String, String)>[];
  final sentSubIds = <int?>[];
  LaunchRequest? launch;
  final _events = StreamController<String>.broadcast();
  int _nextId = 1000;

  void receive(int thread, String address, String body, {DateTime? at, int? subId}) {
    threads.putIfAbsent(thread, () => []).add(StoredMessage(
        id: _nextId++, address: address, body: body, date: at ?? DateTime.now(), status: StoredStatus.received,
        subId: subId));
    _events.add('changed');
  }

  /// An outgoing text already in the store (e.g. sent by a campaign) with a known row id.
  void addSent(int thread, String address, String body, int id) {
    threads.putIfAbsent(thread, () => []).add(StoredMessage(
        id: id, address: address, body: body, date: DateTime.now(), status: StoredStatus.delivered));
  }

  @override Future<bool> isDefault() async => isDefaultApp;
  @override
  Future<bool> requestDefault() async {
    if (grantOnRequest) {
      isDefaultApp = true;
      if (bg != null) bg!.current = FakeBackground.copy(bg!.current, defaultSms: true, sms: true);
    }
    return isDefaultApp;
  }
  @override Future<void> openDefaultAppsSettings() async {}
  @override
  Future<List<ConversationSummary>> conversations() async => [
        for (final e in threads.entries)
          ConversationSummary(
            threadId: e.key, addresses: [e.value.last.address], name: names[e.key], snippet: e.value.last.body,
            date: e.value.last.date,
            unread: readThreads.contains(e.key) ? 0 : e.value.where((m) => m.incoming).length,
          ),
      ]..sort((a, b) => b.date.compareTo(a.date));
  @override Future<List<StoredMessage>> messages(int threadId, {int limit = 200}) async => [...?threads[threadId]];
  @override
  Future<int> threadIdFor(String address) async =>
      threads.entries.where((e) => e.value.any((m) => m.address == address)).firstOrNull?.key ?? 999;
  @override Future<void> markRead(int threadId) async => readThreads.add(threadId);
  @override Future<void> markAllRead() async => readThreads.addAll(threads.keys);
  @override
  Future<bool> deleteMessage(int id) async {
    for (final l in threads.values) {
      final before = l.length;
      l.removeWhere((m) => m.id == id);
      if (l.length != before) { _events.add('changed'); return true; }
    }
    return false;
  }
  @override
  Future<bool> deleteThread(int threadId) async {
    final ok = threads.remove(threadId) != null;
    if (ok) _events.add('changed');
    return ok;
  }
  @override
  Future<bool> send(String address, String body, {int? subId}) async {
    if (!isDefaultApp) return false;
    sent.add((address, body));
    sentSubIds.add(subId);
    final t = await threadIdFor(address);
    threads.putIfAbsent(t, () => []).add(StoredMessage(
        id: _nextId++, address: address, body: body, date: DateTime.now(), status: StoredStatus.sent, subId: subId));
    return true;
  }
  @override Future<LaunchRequest?> takeLaunch() async { final l = launch; launch = null; return l; }

  /// Like Android delivering a notification tap / "send SMS to" while the app runs.
  void open(LaunchRequest l) {
    launch = l;
    _events.add('launch');
  }
  @override Stream<String> get events => _events.stream;
}

/// Phone contacts: by default none, permission granted; [snapshot] is what a sync returns.
class FakePhoneContactsBase implements PhoneContactsService {
  ContactsSnapshot snapshot = const ContactsSnapshot(contacts: [], now: 1, full: true);
  final syncedSince = <int>[];
  final edited = <Contact>[];
  @override Future<bool> hasPermission() async => true;
  @override Future<bool> requestPermission() async => true;
  @override Future<List<PhoneContact>> load() async => const [];
  @override
  Future<ContactsSnapshot> sync({int since = 0}) async {
    syncedSince.add(since);
    return snapshot;
  }
  @override
  Future<bool> edit(Contact contact) async {
    edited.add(contact);
    return true;
  }
}
