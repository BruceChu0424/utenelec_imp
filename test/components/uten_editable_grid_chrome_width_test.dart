// 表格输入格「装饰宽度」契约（B2-b/B2-d/B2-f，2026-09-11 补测）：
//  1. chromeWidth 计入表体，随后取表体和表头较宽的一项；
//  2. 列头 ⓘ 走统一的 UtenColumnHintIcon：点按弹说明、长按被吞掉，
//     不会 arm 列头的拖拽隐藏/排序手势。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

class _CurrencyRow extends EditableGridRow {
  _CurrencyRow([String text = '人民币']) {
    currency.text = text;
  }

  final TextEditingController currency = TextEditingController();

  @override
  void dispose() {
    currency.dispose();
    super.dispose();
  }
}

/// 返回格内可用宽度（列宽 − 格内边距），由 cellBuilder 的 LayoutBuilder 捕获。
double? cellMaxWidth;

Future<double> _cellWidth(
  WidgetTester tester, {
  required double chromeWidth,
  String? headerInfo,
  String value = '人民币',
}) async {
  cellMaxWidth = null;
  await tester.pumpWidget(const SizedBox.shrink());
  final controller = UtenEditableGridController<_CurrencyRow>(
    initial: [_CurrencyRow(value)],
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            UtenEditableGrid<_CurrencyRow>(
              controller: controller,
              createBlankRow: _CurrencyRow.new,
              columns: [
                EditableGridColumn<_CurrencyRow>(
                  key: 'currency',
                  label: '币种',
                  width: 90,
                  chromeWidth: chromeWidth,
                  headerInfo: headerInfo,
                  textOf: (row) => row.currency.text,
                  listenableOf: (row) => row.currency,
                  cellBuilder: (context, row) => LayoutBuilder(
                    builder: (context, constraints) {
                      cellMaxWidth = constraints.maxWidth;
                      return Row(
                        children: [
                          Flexible(
                            child: Text(
                              row.currency.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (chromeWidth > 0)
                            SizedBox(
                              width: chromeWidth,
                              child: const Icon(Icons.info_outline),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return cellMaxWidth!;
}

void main() {
  testWidgets('chromeWidth 加宽自适应列：44 的图标位不吃默认值', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const value = '美元 USD 结算账户';
    final narrow = await _cellWidth(tester, chromeWidth: 0, value: value);
    final wide = await _cellWidth(tester, chromeWidth: 44, value: value);

    expect(wide - narrow, closeTo(44, 0.5), reason: '表体最宽时，图标位应完整计入');

    final headerWidth = await _cellWidth(tester, chromeWidth: 0, value: '元');
    final chromeWidth = await _cellWidth(tester, chromeWidth: 44, value: '元');
    expect(chromeWidth, greaterThan(headerWidth));
    expect(chromeWidth - headerWidth, lessThan(44));
  });

  testWidgets('列头 ⓘ：点按弹说明，长按不触发列头手势', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _cellWidth(tester, chromeWidth: 44, headerInfo: '按本单币种填写');

    expect(find.byType(UtenColumnHintIcon), findsOneWidget);
    expect(find.byType(UtenFieldHintIcon), findsOneWidget);

    // 长按：被 UtenColumnHintIcon 吞掉，不弹说明也不进入列头拖拽态。
    await tester.longPress(find.byType(UtenColumnHintIcon));
    await tester.pumpAndSettle();
    expect(find.text('按本单币种填写'), findsNothing);

    // 点按：弹出说明。
    await tester.tap(find.byType(UtenColumnHintIcon));
    await tester.pumpAndSettle();
    expect(find.text('按本单币种填写'), findsWidgets);
  });
}
