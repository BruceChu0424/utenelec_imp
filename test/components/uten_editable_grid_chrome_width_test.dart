// 表格输入格「装饰宽度」契约（B2-b/B2-d/B2-f，2026-09-11 补测）：
//  1. chromeWidth 会加到自适应列宽上——格内有预填 ⓘ / 状态图标的列必须多留 44，
//     否则「人民币」这类默认值被图标压到省略号（此前汇率/税率列只算了下拉箭头 20）；
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
}) async {
  cellMaxWidth = null;
  final controller = UtenEditableGridController<_CurrencyRow>(
    initial: [_CurrencyRow()],
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
                      return TextField(
                        controller: row.currency,
                        decoration: const InputDecoration(isDense: true),
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

    final narrow = await _cellWidth(tester, chromeWidth: 0);
    final wide = await _cellWidth(tester, chromeWidth: 44);

    expect(
      wide - narrow,
      closeTo(44, 0.5),
      reason: 'chromeWidth 必须整体加到列宽上，不能被量宽逻辑吞掉',
    );
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
