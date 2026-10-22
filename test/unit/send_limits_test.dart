import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/core/sms/sms_segment_estimator.dart';
import 'package:sim_bulk_sms/domain/models/send_settings.dart';
import 'package:sim_bulk_sms/domain/services/campaign_planner.dart';
import 'package:sim_bulk_sms/domain/services/send_limits.dart';
import 'package:sim_bulk_sms/domain/services/recipient_eligibility.dart';
import 'package:sim_bulk_sms/features/campaigns/message_counter.dart';

void main() {
  final t0 = DateTime(2026, 10, 22, 9);
  List<DateTime> every(Duration step, int n, {DateTime? from}) =>
      [for (var i = 0; i < n; i++) (from ?? t0).add(step * i)];

  group('special characters', () {
    test('plain text has none', () => expect(SmsSegmentEstimator.nonGsmCharacters('Hi Ada, see you @ 8!'), isEmpty));
    test('smart quotes and emoji are listed once each', () =>
        expect(SmsSegmentEstimator.nonGsmCharacters('It’s “great” ’ 🎉'), ['’', '“', '”', '🎉']));
    test('use plain characters fixes keyboard punctuation but not emoji', () {
      expect(SmsSegmentEstimator.toPlainCharacters('It’s “great” – see you…'), 'It\'s "great" - see you...');
      final fixed = SmsSegmentEstimator.toPlainCharacters('Hi ’ 🎉');
      expect(fixed, "Hi ' 🎉");
      expect(SmsSegmentEstimator.estimate(SmsSegmentEstimator.toPlainCharacters('It’s here')).encoding, SmsEncoding.gsm7);
    });
  });

  test('counter uses the longest real message once recipients are known', () {
    final plan = SnapshotPlan(
      recipients: const [
        SnapshotRecipient(name: 'Ada', phoneE164: '+1', renderedMessage: 'Hi Ada'),
        SnapshotRecipient(name: 'Chukwuemeka', phoneE164: '+2', renderedMessage: 'Hi Chukwuemeka'),
      ],
      blocked: const [],
      eligibility: const EligibilityResult([], [], [], []),
      estimate: estimateCampaign(const ['Hi Ada', 'Hi Chukwuemeka']),
      unknownConsentCount: 0,
    );
    expect(messageToCount('Hi {first_name}', plan), (text: 'Hi Chukwuemeka', forName: 'Chukwuemeka'));
    expect(messageToCount('Hi {first_name}', null), (text: 'Hi {first_name}', forName: null));
  });

  group('checkLimits (rolling windows)', () {
    const s = SendSettings(hourlyLimit: 3, dailyLimit: 5);
    test('under both limits: allowed', () =>
        expect(checkLimits(sent: every(const Duration(minutes: 1), 2), now: t0.add(const Duration(minutes: 5)), settings: s), isNull));
    test('hourly limit: resumes when the oldest of the last hour leaves the window', () {
      final hit = checkLimits(sent: every(const Duration(minutes: 10), 3), now: t0.add(const Duration(minutes: 25)), settings: s)!;
      expect(hit.kind, LimitKind.hourly);
      expect(hit.resumeAt, t0.add(const Duration(hours: 1)));
    });
    test('messages older than an hour no longer count for the hourly limit', () =>
        expect(checkLimits(sent: every(const Duration(minutes: 10), 3), now: t0.add(const Duration(minutes: 61)), settings: s), isNull));
    test('daily limit: resumes 24 h after the right send', () {
      final sent = every(const Duration(hours: 2), 5);
      final hit = checkLimits(sent: sent, now: t0.add(const Duration(hours: 9)), settings: s)!;
      expect(hit.kind, LimitKind.daily);
      expect(hit.resumeAt, t0.add(const Duration(hours: 24)));
    });
    test('limits switched off never block', () => expect(
        checkLimits(sent: every(const Duration(seconds: 1), 1000), now: t0.add(const Duration(minutes: 20)),
            settings: const SendSettings(hourlyLimit: 0, dailyLimit: 0)),
        isNull));
  });

  group('estimateFinish', () {
    test('no limits: delay between messages only', () {
      const s = SendSettings(delaySeconds: 3, hourlyLimit: 0, dailyLimit: 0);
      expect(estimateFinish(messages: 100, settings: s, sent: const [], now: t0), t0.add(const Duration(seconds: 297)));
    });
    test('hourly limit spreads a big send over hours', () {
      const s = SendSettings(delaySeconds: 3, hourlyLimit: 100, dailyLimit: 0);
      final end = estimateFinish(messages: 250, settings: s, sent: const [], now: t0);
      // 100 now, 100 an hour later, the last 50 two hours later.
      expect(end, t0.add(const Duration(hours: 2, seconds: 49 * 3)));
    });
    test('already at the daily limit: starts when it frees up', () {
      const s = SendSettings(delaySeconds: 3, hourlyLimit: 0, dailyLimit: 2);
      final end = estimateFinish(messages: 1, settings: s, sent: [t0, t0.add(const Duration(minutes: 1))],
          now: t0.add(const Duration(minutes: 5)));
      expect(end, t0.add(const Duration(hours: 24)));
    });
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 30)), 'less than a minute');
    expect(formatDuration(const Duration(minutes: 23)), '23 min');
    expect(formatDuration(const Duration(hours: 4, minutes: 30)), '4 h 30 min');
  });
}
