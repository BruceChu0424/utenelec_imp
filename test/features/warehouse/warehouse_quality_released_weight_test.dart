// IQC 合格入库的「放行重量」(ADR-135 §3.10): 只读, 本次实收按到货实称的放行重量累计分摊
// (与服务端入库切片同口径: 4 位四舍五入、末批取余); 到货没称显示「未称」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_merged_table.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_slice_table.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';

WarehouseQualityReleasedSlice _slice({
  required String id,
  double? releasedWeight,
  double released = 3,
  double stocked = 0,
}) => WarehouseQualityReleasedSlice(
  passEventId: id,
  inspectionItemId: 'line-$id',
  goodsId: 'goods-$id',
  goodsName: '螺丝',
  unitName: '个',
  receivedBaseQty: released,
  qualityPassedBaseQty: released,
  warehouseStockedBaseQty: stocked,
  releasedBaseQty: released,
  stockedForReleaseBaseQty: stocked,
  remainingBaseQty: released - stocked,
  releasedWeight: releasedWeight,
  warehouseId: 'wh-1',
  warehouseName: '五金仓库',
);

WarehouseQualityInspectionLine _line(String id) =>
    WarehouseQualityInspectionLine(
      inspectionItemId: 'line-$id',
      goodsId: 'goods-$id',
      goodsName: '螺丝',
      receivedBaseQty: 3,
      passedBaseQty: 3,
      failedBaseQty: 0,
      warehouseStockedBaseQty: 0,
      pendingStockBaseQty: 3,
      lineStatus: 'DONE',
    );

void main() {
  test('放行重量按累计份额差分摊, 末批取余, 合计等于放行重量', () {
    // 放行 3 个共 1 kg: 分 1 + 1 + 1 三批入库。
    final first = WarehouseQualitySliceDraft(
      _slice(id: 'a', releasedWeight: 1),
    );
    first.quantity.text = '1';
    expect(first.previewWeightKg, 0.3333);

    final second = WarehouseQualitySliceDraft(
      _slice(id: 'a', releasedWeight: 1, stocked: 1),
    );
    second.quantity.text = '1';
    expect(second.previewWeightKg, 0.3334);

    final last = WarehouseQualitySliceDraft(
      _slice(id: 'a', releasedWeight: 1, stocked: 2),
    );
    expect(last.quantity.text, '1'); // 默认 = 剩余量
    expect(last.previewWeightKg, 0.3333);
    expect(
      roundKgLine(
        first.previewWeightKg! +
            second.previewWeightKg! +
            last.previewWeightKg!,
      ),
      1,
    );

    // 到货没称 / 本次数量无效: 没有预览重量。
    final unweighed = WarehouseQualitySliceDraft(_slice(id: 'b'));
    expect(unweighed.previewWeightKg, isNull);
    first.quantity.text = '';
    expect(first.previewWeightKg, isNull);
    for (final draft in [first, second, last, unweighed]) {
      draft.dispose();
    }
  });

  testWidgets('「放行重量」只读列紧跟本次实收, 随实收重算; 没称显示「未称」', (tester) async {
    tester.view.physicalSize = const Size(2200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final weighed = WarehouseQualitySliceDraft(
      _slice(id: 'a', releasedWeight: 1.5),
    );
    final unweighed = WarehouseQualitySliceDraft(_slice(id: 'b'));
    addTearDown(weighed.dispose);
    addTearDown(unweighed.dispose);
    final controller = UtenEditableGridController<WarehouseQualityMergedRow>(
      initial: [
        WarehouseQualityMergedRow(line: _line('a'), draft: weighed),
        WarehouseQualityMergedRow(line: _line('b'), draft: unweighed),
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
                editable: true,
                saving: false,
                onChanged: () {},
                weightDisplay: WeightDisplay.kg,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final labels = tester
        .widget<UtenEditableGrid<WarehouseQualityMergedRow>>(
          find.byType(UtenEditableGrid<WarehouseQualityMergedRow>),
        )
        .columns
        .map((column) => column.label)
        .toList();
    expect(labels[labels.indexOf('本次实收') + 1], '放行重量');
    final columns = tester
        .widget<UtenEditableGrid<WarehouseQualityMergedRow>>(
          find.byType(UtenEditableGrid<WarehouseQualityMergedRow>),
        )
        .columns;
    final quantity = columns.singleWhere((column) => column.key == 'quantity');
    final weight = columns.singleWhere(
      (column) => column.key == 'releasedWeight',
    );
    final firstRow = controller.rows.first;
    expect(quantity.exactValueOf!(firstRow), weighed.quantity.text);
    expect(quantity.exactListenableOf!(firstRow), same(weighed.quantity));
    expect(weight.exactValueOf!(firstRow), '1.5');
    expect(weight.exactListenableOf!(firstRow), same(weighed.quantity));
    expect(weight.exactValueOf!(controller.rows.last), isNull);
    expect(
      quantity.exactValueOf!(
        WarehouseQualityMergedRow(line: _line('readonly')),
      ),
      isNull,
    );
    for (final key in ['remaining', 'received', 'passed', 'failed']) {
      expect(
        columns.singleWhere((column) => column.key == key).exactValueOf!(
          firstRow,
        ),
        key == 'failed' ? '0.0' : '3.0',
      );
    }

    Finder weightOf(String id) =>
        find.byKey(ValueKey('quality-slice-released-weight-$id'));
    // 全额入库 = 放行重量 1.5 kg; 没称的显示「未称」。
    expect(
      tester.widget<Text>(weightOf('a')).data,
      formatWeight(1.5, display: WeightDisplay.kg),
    );
    expect(tester.widget<Text>(weightOf('b')).data, '未称');

    // 改小本次实收 → 按份额重算 (1 / 3 × 1.5 = 0.5 kg)。
    await tester.enterText(find.byKey(const Key('quality-slice-qty-a')), '1');
    await tester.pump();
    expect(quantity.exactValueOf!(firstRow), '1');
    expect(weight.exactValueOf!(firstRow), '0.5');
    expect(
      tester.widget<Text>(weightOf('a')).data,
      formatWeight(0.5, display: WeightDisplay.kg),
    );
  });
}
