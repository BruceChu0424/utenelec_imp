import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/data_display/uten_status_cell_color.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/widgets/inbound_registration_widgets.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Line extends InboundRegistrationLine {
  @override
  String get goodsId => 'g';
  @override
  String get goodsName => '螺丝';
  @override
  String? get colorId => 'red';
}

WeightParams _params(WeightTier tier) => WeightParams(
  key: 'g||w|red',
  goodsId: 'g',
  basis: WeightBasis.learned,
  logMean: -6.214608098422191,
  lotPrior: 0.00001,
  tier: tier,
  stockBalance: const WeightStockBalance(
    warehouseId: 'w',
    colorId: 'red',
    qtyBase: 1000,
    weightKg: 20,
  ),
);

Future<EditableGridColumn<_Line>> _pump(
  WidgetTester tester,
  _Line line,
  ValueNotifier<WeightParams> params,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final columns = InboundGridColumns<_Line>(
    names: MasterNameService(ApiClient(Dio())),
    keyPrefix: 'inbound',
    lineKeyOf: (_) => '1',
    goodsCodeOf: (_) => 'G1',
    colorNameOf: (_) => '红',
    unitNameOf: (_) => '个',
  );
  final column = columns.weightCheck(
    paramsOf: (_) => params.value,
    paramsListenable: params,
    qtyBaseOf: (_) => 1000,
    baseUnitNameOf: (_) => '个',
  );
  final controller = UtenEditableGridController<_Line>(initial: [line]);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            UtenEditableGrid<_Line>(
              controller: controller,
              columns: [column],
              showAddRow: false,
              showRowDelete: false,
              showColumnSettings: false,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return column;
}

void main() {
  testWidgets('未学准但同仓色库存20kg，录入1kg时核对标签与输入格同为黄色提醒', (tester) async {
    final line = _Line()..weight.setKg(1);
    final params = ValueNotifier(_params(WeightTier.red));
    addTearDown(params.dispose);
    final column = await _pump(tester, line, params);
    final tooltip = find.byKey(const ValueKey('inbound-weight-check-1'));
    expect(find.text('数值可能有问题，预计约 20 kg'), findsOneWidget);
    expect(tester.widget<Tooltip>(tooltip).message, contains('-95.0%'));
    final context = tester.element(tooltip);
    expect(
      column.cellColor!(context, line),
      udenStatusBadgeCellColor(context, UtenStatusBadgeType.warning),
    );
    line.weight.setKg(20);
    await tester.pumpAndSettle();
    expect(tooltip, findsNothing);
    expect(column.textOf!(line), isEmpty);
    expect(column.cellColor!(context, line), isNull);
    line.weight.setKg(1, qtyFromWeight: true);
    await tester.pumpAndSettle();
    expect(tooltip, findsNothing);
  });

  testWidgets('入库可靠历史优先：历史2kg与库存20kg不互相覆盖或产生矛盾提示', (tester) async {
    final line = _Line()..weight.setKg(2);
    final params = ValueNotifier(_params(WeightTier.green));
    addTearDown(params.dispose);
    final column = await _pump(tester, line, params);
    expect(column.textOf!(line), isEmpty);
    line.weight.setKg(20);
    await tester.pumpAndSettle();
    final tooltip = find.byKey(const ValueKey('inbound-weight-check-1'));
    expect(tooltip, findsOneWidget);
    expect(tester.widget<Tooltip>(tooltip).message, contains('应重 2 kg'));
    final context = tester.element(tooltip);
    expect(
      column.cellColor!(context, line),
      udenStatusBadgeCellColor(context, UtenStatusBadgeType.warning),
    );
  });
}
