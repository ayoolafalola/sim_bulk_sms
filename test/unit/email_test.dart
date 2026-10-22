import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/data/database/app_database.dart';
import 'package:sim_bulk_sms/data/repositories/attempt_repository.dart';
import 'package:sim_bulk_sms/data/repositories/campaign_repository.dart';
import 'package:sim_bulk_sms/data/repositories/settings_repository.dart';
import 'package:sim_bulk_sms/domain/models/channels.dart';
import 'package:sim_bulk_sms/domain/models/contact.dart';
import 'package:sim_bulk_sms/domain/models/email_settings.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/domain/services/email_body.dart';
import 'package:sim_bulk_sms/features/sms_sending/send_orchestrator.dart';
import 'package:sim_bulk_sms/platform/email/email_sender.dart';
import 'package:sim_bulk_sms/platform/email/gmail_sender.dart';
import 'package:sim_bulk_sms/platform/email/mailgun_sender.dart';
import 'package:sim_bulk_sms/platform/sms/sms_capability_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const mailgun = EmailSettings(
  provider: EmailProvider.mailgun, domain: 'mg.example.com', apiKey: 'key-123',
  fromName: 'Grace Church', fromAddress: 'news@mg.example.com',
);

/// Records requests and answers with [status]/[body], or throws [error].
class FakePost {
  FakePost({this.status = 200, this.body = '{"id":"<1@mg>","message":"Queued. Thank you."}', this.error});
  int status;
  String body;
  Object? error;
  final requests = <({Uri url, Map<String, String> headers, String body})>[];
  Future<HttpReply> call(Uri url, Map<String, String> headers, List<int> body) async {
    requests.add((url: url, headers: headers, body: utf8.decode(body)));
    if (error != null) throw error!;
    return HttpReply(status, this.body);
  }
}

class FakeGmailAuth implements GmailAuth {
  final tokens = ['t1', 't2'];
  final cleared = <String>[];
  @override
  Future<String?> token() async => tokens.isEmpty ? null : tokens.first;
  @override
  Future<void> clear(String token) async {
    cleared.add(token);
    tokens.remove(token);
  }
}

const androidOk = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: true,
    usesComposerHandoff: false, canSelectSim: false, blocker: DirectSendBlocker.none);
const ios = SmsCapabilities(platform: SmsPlatform.ios, canSendDirectly: false,
    usesComposerHandoff: true, canSelectSim: false, blocker: DirectSendBlocker.none);

class FakeSms implements SmsCapabilityService {
  FakeSms(this.caps);
  final SmsCapabilities caps;
  final sentTo = <String>[];
  final controller = StreamController<SmsEvent>.broadcast();
  @override Future<SmsCapabilities> getCapabilities() async => caps;
  @override Future<bool> requestRequiredPermissions() async => true;
  @override Future<List<SimSubscription>> getAvailableSubscriptions() async => const [];
  @override Stream<SmsEvent> get events => controller.stream;
  @override
  Future<SmsOperationResult> sendMessage(SmsSendRequest r) async {
    sentTo.add(r.phoneE164);
    return const SmsOperationResult(RecipientStatus.submitted);
  }
}

void main() {
  group('planner channels', () {
    const ada = Contact(id: 1, name: 'Ada Okafor', phoneRaw: '0803', phoneNormalized: '+2348031234567', email: 'ada@example.com');
    const bola = Contact(id: 2, name: 'Bola', phoneRaw: '', email: 'bola@example.com'); // email only
    const chidi = Contact(id: 3, name: 'Chidi', phoneRaw: '0805', phoneNormalized: '+2348051234567'); // number only
    const all = [ada, bola, chidi];

    SnapshotPlan plan(SendChannel ch, {String subject = 'Hi {first_name}', Set<String> suppressed = const {}}) =>
        buildSnapshotPlan(template: 'Hello {first_name}', contacts: all, suppressedE164: suppressed,
            channel: ch, subjectTemplate: subject);

    test('SMS: only people with numbers', () {
      final p = plan(SendChannel.sms);
      expect(p.recipients.map((r) => r.name), ['Ada Okafor', 'Chidi']);
      expect(p.emailCount, 0);
      expect(p.eligibility.excludedInvalid.map((c) => c.name), ['Bola']);
    });

    test('Email: only people with addresses; subject rendered per person', () {
      final p = plan(SendChannel.email);
      expect(p.recipients.map((r) => r.email), ['ada@example.com', 'bola@example.com']);
      expect(p.recipients.every((r) => r.channel == MessageChannel.email), true);
      expect(p.recipients.first.subject, 'Hi Ada');
      expect(p.estimate.messages, 0); // no SMS segments
    });

    test('Both: a text and an email for people with both', () {
      final p = plan(SendChannel.both);
      expect(p.smsCount, 2);
      expect(p.emailCount, 2);
      expect(p.recipients.where((r) => r.contactId == 1).length, 2);
    });

    test('Text, else email: email only for people without a number', () {
      final p = plan(SendChannel.smsElseEmail);
      expect([for (final r in p.recipients) '${r.name}:${r.channel.name}'], ['Ada Okafor:sms', 'Bola:email', 'Chidi:sms']);
    });

    test('suppressed and opted-out people get no email either; each address once', () {
      final p = buildSnapshotPlan(template: 'x', subjectTemplate: 's', channel: SendChannel.email, suppressedE164: {
        '+2348031234567',
      }, contacts: const [
        ada,
        Contact(id: 4, name: 'Out', phoneRaw: '', email: 'out@example.com', consent: ConsentStatus.optedOut),
        bola,
        Contact(id: 5, name: 'Bola twin', phoneRaw: '', email: 'BOLA@example.com'),
      ]);
      expect(p.recipients.map((r) => r.name), ['Bola']);
      expect(p.eligibility.excludedSuppressed.single.name, 'Ada Okafor');
      expect(p.eligibility.excludedOptedOut.single.name, 'Out');
    });

    test('a placeholder missing only in the subject blocks the email', () {
      final p = plan(SendChannel.email, subject: 'About {company}');
      expect(p.recipients, isEmpty);
      expect(p.unresolvedVariables, {'company'});
    });
  });

  group('email body and settings', () {
    test('plain and HTML versions with the unsubscribe line; HTML is escaped', () {
      final b = emailBodies('Hi <Ada>\nSee you', mailgun);
      expect(b.text, endsWith(EmailSettings.defaultUnsubscribeText));
      expect(b.html, contains('Hi &lt;Ada&gt;<br>See you'));
      expect(emailBodies('x', mailgun.copyWith(unsubscribeOn: false)).text, 'x');
    });

    test('settings round-trip and readiness', () {
      final back = EmailSettings.fromJson(mailgun.toJson());
      expect(back.domain, 'mg.example.com');
      expect(back.ready, true);
      expect(mailgun.copyWith(apiKey: '').ready, false);
      expect(const EmailSettings().ready, false);
      expect(EmailSettings.fromJson(null).hourlyLimit, 50);
    });
  });

  group('Mailgun-compatible sender', () {
    const email = OutgoingEmail(id: 'cr-7-a3', campaignId: 12, toAddress: 'ada@example.com', toName: 'Ada Okafor',
        subject: 'Harvest Sunday', text: 'Hi Ada', html: '<div>Hi Ada</div>');

    test('POSTs the form to {base}/{domain}/messages with Basic auth api:KEY', () async {
      final post = FakePost();
      final r = await MailgunSender(mailgun, post: post.call).send(email);
      expect(r.outcome, EmailOutcome.sent);
      expect(r.providerId, '<1@mg>');
      final req = post.requests.single;
      expect(req.url.toString(), 'https://api.mailgun.net/v3/mg.example.com/messages');
      expect(req.headers['Authorization'], 'Basic ${base64.encode(utf8.encode('api:key-123'))}');
      final f = Uri.splitQueryString(req.body);
      expect(f['from'], '"Grace Church" <news@mg.example.com>');
      expect(f['to'], '"Ada Okafor" <ada@example.com>');
      expect(f['subject'], 'Harvest Sunday');
      expect(f['text'], 'Hi Ada');
      expect(f['html'], '<div>Hi Ada</div>');
      expect(f['v:campaign_id'], '12');
      expect(f['v:message_id'], 'cr-7-a3');
      expect(f['h:List-Unsubscribe'], '<mailto:news@mg.example.com?subject=unsubscribe>');
    });

    test('another Mailgun-style service: just a different base URL', () async {
      final post = FakePost();
      await MailgunSender(mailgun.copyWith(baseUrl: 'https://mail.example.org/api/'), post: post.call).send(email);
      expect(post.requests.single.url.toString(), 'https://mail.example.org/api/mg.example.com/messages');
    });

    test('4xx fails, 5xx and timeouts are unknown, no connection fails', () async {
      Future<EmailResult> send(FakePost p) => MailgunSender(mailgun, post: p.call).send(email);
      final r401 = await send(FakePost(status: 401, body: 'Forbidden'));
      expect((r401.outcome, r401.errorCode), (EmailOutcome.failed, 'auth'));
      final r400 = await send(FakePost(status: 400, body: '{"message":"to parameter is not a valid address"}'));
      expect((r400.outcome, r400.errorMessage), (EmailOutcome.failed, 'to parameter is not a valid address'));
      expect((await send(FakePost(status: 502))).outcome, EmailOutcome.unknown);
      expect((await send(FakePost(error: TimeoutException('slow')))).outcome, EmailOutcome.unknown);
      final off = await send(FakePost(error: RequestNotSentException('no network')));
      expect((off.outcome, off.errorCode), (EmailOutcome.failed, 'network'));
    });
  });

  group('Gmail sender', () {
    const gmail = EmailSettings(provider: EmailProvider.gmail, fromName: 'Grace', gmailAccount: 'me@gmail.com');
    const email = OutgoingEmail(id: 'cr-1-a1', campaignId: 1, toAddress: 'ada@example.com', toName: 'Adá',
        subject: 'Ẹ káàbọ̀', text: 'Hi', html: '<b>Hi</b>');

    test('sends the message as base64url MIME with a Bearer token', () async {
      final post = FakePost(body: '{"id":"g1"}');
      final s = GmailSender(gmail, FakeGmailAuth(), post: post.call);
      await s.prepare();
      final r = await s.send(email);
      expect((r.outcome, r.providerId), (EmailOutcome.sent, 'g1'));
      expect(post.requests.single.headers['Authorization'], 'Bearer t1');
      final raw = (jsonDecode(post.requests.single.body) as Map)['raw'] as String;
      final mime = utf8.decode(base64Url.decode(base64Url.normalize(raw)));
      expect(mime, contains('To: =?UTF-8?B?'));
      expect(mime, contains('Subject: =?UTF-8?B?${base64.encode(utf8.encode('Ẹ káàbọ̀'))}?='));
      expect(mime, contains('Content-Type: multipart/alternative'));
      expect(mime, contains(base64.encode(utf8.encode('<b>Hi</b>'))));
    });

    test('an expired token is refreshed once', () async {
      final auth = FakeGmailAuth();
      var calls = 0;
      Future<HttpReply> post(Uri u, Map<String, String> h, List<int> b) async =>
          ++calls == 1 ? const HttpReply(401, '{}') : const HttpReply(200, '{"id":"g2"}');
      final s = GmailSender(gmail, auth, post: post);
      await s.prepare();
      expect((await s.send(email)).outcome, EmailOutcome.sent);
      expect(auth.cleared, ['t1']);
    });

    test('no token: sending does not start', () async {
      final auth = FakeGmailAuth()..tokens.clear();
      expect(GmailSender(gmail, auth).prepare(), throwsA(isA<EmailNotReadyException>()));
    });
  });

  group('sending emails', () {
    sqfliteFfiInit();
    late Database db;
    late CampaignRepository campaigns;
    late AttemptRepository attempts;
    late SettingsRepository settings;
    late FakePost post;

    setUp(() async {
      db = await openAppDatabase(databaseFactoryFfi, inMemoryDatabasePath);
      campaigns = CampaignRepository(db);
      attempts = AttemptRepository(db);
      settings = SettingsRepository(db);
      post = FakePost();
      await settings.saveEmail(mailgun);
    });
    tearDown(() => db.close());

    SendOrchestrator orch(SmsCapabilities caps, {bool emailOn = true}) => SendOrchestrator(
          sms: FakeSms(caps), attempts: attempts, campaigns: campaigns, settings: settings,
          emailSender: () async => emailOn ? MailgunSender(await settings.loadEmail(), post: post.call) : null,
          sleep: (_) async {},
        );

    Future<int> campaign({int texts = 1, int emails = 2}) async {
      final id = await campaigns.createDraft(
          name: 'Mixed', template: 'x', platform: 'android', channel: SendChannel.both, subject: 'S');
      await campaigns.saveSnapshot(id, [
        for (var i = 1; i <= texts; i++) SnapshotRecipient(name: 'T$i', phoneE164: '+100$i', renderedMessage: 'Hi'),
        for (var i = 1; i <= emails; i++)
          SnapshotRecipient(name: 'E$i', phoneE164: '', renderedMessage: 'Hi', channel: MessageChannel.email,
              email: 'e$i@example.com', subject: 'Subject $i'),
      ]);
      return id;
    }

    test('Android sends texts through the SIM and emails through the API', () async {
      final id = await campaign();
      final o = orch(androidOk);
      await o.runAndroid(id);
      expect(post.requests.map((r) => Uri.splitQueryString(r.body)['to']), ['"E1" <e1@example.com>', '"E2" <e2@example.com>']);
      expect(Uri.splitQueryString(post.requests.first.body)['subject'], 'Subject 1');
      final rows = await campaigns.recipients(id);
      expect(rows.where((r) => r.isEmail).every((r) => r.status == RecipientStatus.sent), true);
      final ids = await db.query('send_attempts', columns: ['native_operation_id'], where: "platform = 'email'");
      expect(ids.first['native_operation_id'], '<1@mg>');
    });

    test('iPhone: emails go by themselves; texts wait for you', () async {
      final id = await campaign();
      await orch(ios).runEmails(id);
      final rows = await campaigns.recipients(id);
      expect(rows.where((r) => r.isEmail).map((r) => r.status).toSet(), {RecipientStatus.sent});
      expect(rows.where((r) => !r.isEmail).single.status, RecipientStatus.pending);
      expect((await campaigns.get(id))!.status, CampaignStatus.awaitingUserAction);
    });

    test('an email-only campaign finishes without the SIM (e.g. not the default app)', () async {
      final id = await campaign(texts: 0);
      const blocked = SmsCapabilities(platform: SmsPlatform.android, canSendDirectly: false, usesComposerHandoff: true,
          canSelectSim: false, blocker: DirectSendBlocker.notDefaultApp);
      await orch(blocked).runAndroid(id);
      expect((await campaigns.get(id))!.status, CampaignStatus.completed);
    });

    test('email not set up: nothing is sent', () async {
      final id = await campaign();
      await expectLater(orch(androidOk, emailOn: false).runAndroid(id), throwsA(isA<EmailNotReadyException>()));
      expect((await campaigns.statusCounts(id))[RecipientStatus.pending], 3);
    });

    test('a refused API key stops sending after the first email', () async {
      post.status = 401;
      final id = await campaign(texts: 0);
      await orch(androidOk).runAndroid(id);
      expect(post.requests, hasLength(1));
      expect((await campaigns.get(id))!.status, CampaignStatus.paused);
    });

    test('a server error leaves that email unknown (never resent by itself)', () async {
      post.status = 503;
      final id = await campaign(texts: 0, emails: 1);
      await orch(androidOk).runAndroid(id);
      expect((await campaigns.recipients(id)).single.status, RecipientStatus.unknown);
    });

    test('email limits pause the campaign separately from SMS limits', () async {
      await settings.saveEmail(mailgun.copyWith(hourlyLimit: 1, dailyLimit: 0));
      final id = await campaign(texts: 0, emails: 3);
      final hit = await orch(androidOk).runAndroid(id);
      expect(hit?.email, true);
      expect(post.requests, hasLength(1));
      final c = (await campaigns.get(id))!;
      expect((c.status, c.pausedReason), (CampaignStatus.paused, 'email_hourly_limit'));
      expect(await attempts.sendTimesSince(DateTime.now().subtract(const Duration(hours: 1))), isEmpty); // SMS count untouched
    });
  });
}
