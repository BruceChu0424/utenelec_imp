import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_month_field.dart';

void main() {
  test('年月兼容中文及旧ISO日期，非法月份或溢出日拒绝', () {
    expect(UtenMonthField.parse('2008年7月'), DateTime(2008, 7));
    expect(UtenMonthField.parse('2008-07-31'), DateTime(2008, 7));
    expect(UtenMonthField.parse('2008-13'), isNull);
    expect(UtenMonthField.parse('2008-02-31'), isNull);
  });

  testWidgets('年月允许手输和清空，值变化实时回传', (tester) async {
    String? value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenMonthField(
            label: '制造年月',
            value: '2008年7月',
            onChanged: (next) => value = next,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '1999年12月');
    expect(value, '1999-12');
    await tester.enterText(find.byType(TextField), '1999-13');
    expect(value, '1999-13');
    await tester.pump();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    expect(value, isNull);
  });

  for (final date in [DateTime(2001), DateTime(2200)]) {
    testWidgets('共享日期控件可安全打开区间外已有值 $date', (tester) async {
      DateTime? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenDateField(
              label: '历史日期',
              value: date,
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(UtenDateField));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(changed, isNull, reason: '打开日历不修改历史原值');
    });
  }
}
