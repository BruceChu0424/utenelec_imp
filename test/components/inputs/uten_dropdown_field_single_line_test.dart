// 2026-09-16 回归锁：UtenDropdownField 格内值单行省略号——超宽值不折行
// 撑高字段（采购付款/结账方式「选完变两行」根因）。列宽自适应由网格
// textOf 兜底，字段自身超宽一律省略号。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

const _longLabel = '月结60天（票到验收合格后60天内电汇付款，超期计息）';

void main() {
  testWidgets('长选中值单行省略号，不折行撑高字段', (tester) async {
    final shortHeight = await _pumpField(tester, '人民币');
    final longHeight = await _pumpField(tester, _longLabel);

    final valueText = tester.widget<Text>(find.text(_longLabel));
    expect(valueText.maxLines, 1, reason: '超宽值必须单行省略号，不得折行。');
    expect(valueText.overflow, TextOverflow.ellipsis);
    // 同一字段宽度下，长值与短值字段高度一致（没有多出一行）。
    expect(longHeight, moreOrLessEquals(shortHeight, epsilon: 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('未选时超长 hint 不折行撑高字段', (tester) async {
    final withValue = await _pumpField(tester, '人民币');
    final withLongHint = await _pumpField(
      tester,
      null,
      hint: '请选择付款方式（超长提示文案测试）',
    );
    expect(withLongHint, moreOrLessEquals(withValue, epsilon: 0.5));
    expect(tester.takeException(), isNull);
  });
}

Future<double> _pumpField(
  WidgetTester tester,
  String? selected, {
  String hint = '点击选择',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            child: UtenDropdownField(
              value: selected,
              hintText: hint,
              items: const [
                UtenDropdownItem(value: 'cny', label: '人民币'),
                UtenDropdownItem(value: 'long', label: _longLabel),
              ],
              onChanged: (v) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.getSize(find.byType(UtenDropdownField)).height;
}
