import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/core/sms/sms_segment_estimator.dart';
import 'package:sim_bulk_sms/core/templates/template_renderer.dart';
import 'package:sim_bulk_sms/domain/models/statuses.dart';
import 'package:sim_bulk_sms/domain/services/recipient_state_machine.dart';

void main() {
  group('SmsSegmentEstimator', () {
    test('empty = 0 segments', () => expect(SmsSegmentEstimator.estimate('').segments, 0));
    test('160 GSM chars = 1 segment', () {
      final e = SmsSegmentEstimator.estimate('a' * 160);
      expect([e.encoding, e.segments], [SmsEncoding.gsm7, 1]);
    });
    test('161 GSM chars = 2 segments', () => expect(SmsSegmentEstimator.estimate('a' * 161).segments, 2));
    test('extension chars count double', () {
      final e = SmsSegmentEstimator.estimate('€' * 80);
      expect([e.units, e.segments], [160, 1]);
      expect(SmsSegmentEstimator.estimate('€' * 81).segments, 2);
    });
    test('one Unicode char switches whole message to UCS-2', () {
      final e = SmsSegmentEstimator.estimate('${'a' * 70}é̃'); // combining mark is non-GSM
      expect(e.encoding, SmsEncoding.ucs2);
    });
    test('UCS-2 limits 70 / 67', () {
      expect(SmsSegmentEstimator.estimate('ж' * 70).segments, 1);
      expect(SmsSegmentEstimator.estimate('ж' * 71).segments, 2);
      expect(SmsSegmentEstimator.estimate('ж' * 134).segments, 2);
      expect(SmsSegmentEstimator.estimate('ж' * 135).segments, 3);
    });
    test('emoji counts as 2 UTF-16 units', () => expect(SmsSegmentEstimator.estimate('😀').units, 2));
  });

  group('TemplateRenderer', () {
    test('renders built-ins', () {
      final r = TemplateRenderer.render('Hi {first_name}!', name: 'Ada Lovelace', phone: '+234');
      expect(r.text, 'Hi Ada!');
    });
    test('unresolved variable blocks output', () {
      final r = TemplateRenderer.render('Hi {name}, {event_name}', name: 'Ada', phone: '+1');
      expect(r.ok, false); expect(r.text, isNull); expect(r.unresolved, {'event_name'});
    });
    test('explicit fallback resolves', () {
      final r = TemplateRenderer.render('{event_name}', name: 'A', phone: '+1', fallbacks: {'event_name': 'our event'});
      expect(r.text, 'our event');
    });
    test('blank value is treated as missing', () {
      final r = TemplateRenderer.render('{last_name}', name: 'Ada', phone: '+1');
      expect(r.ok, false);
    });
  });

  group('RecipientStateMachine', () {
    test('cancelled composer never becomes sent', () =>
        expect(RecipientStateMachine.applyOrIgnore(RecipientStatus.cancelled, RecipientStatus.sent), RecipientStatus.cancelled));
    test('duplicate delivered callback is ignored', () =>
        expect(RecipientStateMachine.applyOrIgnore(RecipientStatus.delivered, RecipientStatus.failed), RecipientStatus.delivered));
    test('submitted -> sent -> delivered', () {
      var s = RecipientStatus.submitted;
      s = RecipientStateMachine.applyOrIgnore(s, RecipientStatus.sent);
      s = RecipientStateMachine.applyOrIgnore(s, RecipientStatus.delivered);
      expect(s, RecipientStatus.delivered);
    });
    test('in-flight becomes unknown after interruption, not failed/pending', () {
      expect(RecipientStateMachine.recoverAfterInterruption(RecipientStatus.submitted), RecipientStatus.unknown);
      expect(RecipientStateMachine.recoverAfterInterruption(RecipientStatus.pending), RecipientStatus.pending);
    });
    test('unknown/sent are never auto-retryable', () {
      expect(RecipientStatus.unknown.mayHaveBeenSent, true);
      expect(RecipientStatus.failed.mayHaveBeenSent, false);
    });
  });
}
