// 品质检查结果合并明细表（UtenEditableGrid）的表头快速筛选回归测试。
//
// 2026-09-11「表头快速筛选补齐」批次的清扫页之一：合格/不合格混排的长明细里，
// 「判定结果」「货品名称」给表头下拉，与下达车间页同一套 filterValueOf 机制。
//
// 2026-09-27「表头右键菜单全站统一」：本表宿主未显式开 showColumnSettings，
// 靠默认翻转获得固定/移动/隐藏菜单——这里补默认形态的菜单回归。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_merged_table.dart';

WarehouseQualityInspectionLine _line({
  required String id,
  required String goodsName,
  required double passed,
  required double failed,
}) => WarehouseQualityInspectionLine(
  inspectionItemId: id,
  goodsId: 'goods-$id',
  goodsName: goodsName,
  receivedBaseQty: passed + failed,
  passedBaseQty: passed,
  failedBaseQty: failed,
  warehouseStockedBaseQty: 0,
  pendingStockBaseQty: 0,
  lineStatus: 'DONE',
);

Finder _headerFilter(String label) =>
    find.widgetWithText(GridHeaderFilterCell, label);

void main() {
  testWidgets('判定结果 / 货品名称 表头筛选可收敛明细行', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = UtenEditableGridController<WarehouseQualityMergedRow>(
      initial: [
        WarehouseQualityMergedRow(
          line: _line(id: 'a', goodsName: '甲物料', passed: 10, failed: 0),
        ),
        WarehouseQualityMergedRow(
          line: _line(id: 'b', goodsName: '乙物料', passed: 0, failed: 4),
        ),
        WarehouseQualityMergedRow(
          line: _line(id: 'c', goodsName: '甲物料', passed: 6, failed: 0),
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WarehouseQualityMergedTable(
                controller: controller,
                editable: false,
                saving: false,
                onChanged: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_headerFilter('判定结果'), findsOneWidget);
    expect(_headerFilter('货品名称'), findsOneWidget);

    // 判定结果：合格 2 / 不合格 1。
    await tester.tap(_headerFilter('判定结果'));
    await tester.pumpAndSettle();
    expect(find.text('合格（2）'), findsOneWidget);
    await tester.tap(find.text('不合格（1）'));
    await tester.pumpAndSettle();
    expect(find.text('乙物料'), findsOneWidget);
    expect(find.text('甲物料'), findsNothing);

    // 撤回后按货品名筛选：同名货品的两行合并为一个桶。
    await tester.tap(_headerFilter('不合格'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有'));
    await tester.pumpAndSettle();
    await tester.tap(_headerFilter('货品名称'));
    await tester.pumpAndSettle();
    expect(find.text('甲物料（2）'), findsOneWidget);
    await tester.tap(find.text('甲物料（2）'));
    await tester.pumpAndSettle();
    expect(find.text('乙物料'), findsNothing);
    // 两行数据 + 表头显示的当前筛选值。
    expect(find.text('甲物料'), findsNWidgets(3));
  });

  testWidgets('默认即有表头右键菜单：隐藏列与「表头设置」入口随默认翻转而来', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = UtenEditableGridController<WarehouseQualityMergedRow>(
      initial: [
        WarehouseQualityMergedRow(
          line: _line(id: 'a', goodsName: '甲物料', passed: 10, failed: 0),
        ),
        WarehouseQualityMergedRow(
          line: _line(id: 'b', goodsName: '乙物料', passed: 0, failed: 4),
        ),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WarehouseQualityMergedTable(
                controller: controller,
                editable: false,
                saving: false,
                onChanged: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认翻转后操作条带「表头设置」入口（此前本表宿主从未显式开启）。
    expect(find.textContaining('表头设置'), findsOneWidget);

    // 右击「判定结果」筛选表头（判定列无快照源 → 固定置灰，隐藏/移动可用）。
    final gesture = await tester.startGesture(
      tester.getCenter(_headerFilter('判定结果')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
    expect(find.text('固定到左侧'), findsOneWidget);
    expect(find.text('向左移一格'), findsOneWidget);
    expect(find.text('隐藏此列'), findsOneWidget);

    // 隐藏生效：判定列表头（筛选格）与表体判定单元一起消失。
    await tester.tap(find.text('隐藏此列'));
    await tester.pumpAndSettle();
    expect(_headerFilter('判定结果'), findsNothing);
    expect(find.text('合格'), findsNothing);
    expect(find.text('不合格'), findsNothing);
  });
}
