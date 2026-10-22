import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bulk_sms/features/campaigns/message_counter.dart';

void main() {
  Future<String?> show(WidgetTester t, String text) async {
    String? fixed;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageCounter(template: text, onUsePlain: (v) => fixed = v))));
    if (find.text('Use plain characters').evaluate().isNotEmpty) {
      await t.tap(find.text('Use plain characters'));
    }
    return fixed;
  }

  testWidgets('plain message: characters, SMS count, room left', (t) async {
    expect(await show(t, 'Hello church family'), isNull);
    expect(find.text('19 characters · 1 SMS · 141 left in this SMS'), findsOneWidget);
    expect(find.textContaining('Special characters'), findsNothing);
  });

  testWidgets('smart quotes: warns, names them, and offers the fix', (t) async {
    final fixed = await show(t, 'It’s “Sunday”');
    expect(find.text('13 characters · 1 SMS · 57 left in this SMS'), findsOneWidget);
    expect(find.textContaining('Special characters (’ “ ”)'), findsOneWidget);
    expect(fixed, 'It\'s "Sunday"');
  });

  testWidgets('emoji only: warns but there is nothing to fix', (t) async {
    expect(await show(t, 'Happy Sunday 🎉'), isNull);
    expect(find.textContaining('Special characters (🎉)'), findsOneWidget);
    expect(find.text('Use plain characters'), findsNothing);
  });

  testWidgets('long message shows two SMS', (t) async {
    await show(t, 'a' * 161);
    expect(find.text('161 characters · 2 SMS · 145 left in this SMS'), findsOneWidget);
  });
}
