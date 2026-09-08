import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';

// 全站「字段说明收进 ⓘ」约定（fieldLabel，required_field_decoration.dart）：
// 静态说明挂标签旁 info_outline 悬停提示，不常驻输入框下方；
// Autofill reminders now use an in-field warning icon.
void main() {
  const info = '最多 6 位小数；同一收款批次的全部 AR 分配共用该汇率';

  Widget host({required double width, required Widget child}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );
  }

  testWidgets('UtenInput puts static info inside the input', (tester) async {
    await tester.pumpWidget(
      host(
        width: 260,
        child: const UtenInput(label: '当前批次实际汇率', info: info, required: true),
      ),
    );

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byTooltip(info), findsOneWidget);
    // 说明文字不再是常驻可见文本。
    expect(find.text(info), findsNothing);
    // 必填红 * 仍在标签上。
    expect(find.textContaining('当前批次实际汇率 *'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('UtenDropdownField in-field info icon survives narrow width', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        width: 140,
        child: UtenDropdownField(
          label: '默认成品仓',
          required: true,
          info: '按您上次登记的仓库预选',
          value: null,
          items: const [UtenDropdownItem(value: 'w1', label: '成品一仓')],
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byTooltip('按您上次登记的仓库预选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('UtenDropdownField discloses autofill notice inside the field', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        width: 260,
        child: UtenDropdownField(
          label: '默认成品仓',
          value: 'w1',
          autofilled: true,
          items: const [UtenDropdownItem(value: 'w1', label: '成品一仓')],
          onChanged: (_) {},
        ),
      ),
    );

    // Short reminders are also disclosed through the warning icon.
    expect(find.text('已按上次记录预填，请核对'), findsNothing);
    expect(find.byTooltip('已按上次记录预填，请核对'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
  });

  testWidgets('UtenDateField carries info icon inside the date field', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        width: 220,
        child: UtenDateField(
          label: '最后交货日',
          value: DateTime(2026, 9, 4),
          info: '超过该日期未交货将触发跟单提醒',
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byTooltip('超过该日期未交货将触发跟单提醒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
