// 采集表格「实称重量」列契约 (ADR-135 §6.2):
//  1. 带单位后缀输入 (850g) 换成千克, 失焦后规范成列单位;
//  2. 勾选多行后改一行重量只改这一行 (重量是一次物理称重, 永不批量);
//  3. 货品按重量计时只读「=25 kg」;
//  4. 占位「约 / 应称 / 可选」与 WARN 琥珀 / ALERT 红 状态, 未学准不核对;
//  5. 数量空着时按称重推算数量 (黄框), 改数量不恢复学习资格, 改重量才清标记;
//  6. 工具条「称重单位」切换后表头与已填文本跟着换单位, 千克值不变。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/shared/measurement/weight_params.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_grid_column.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_text.dart';

class _MemoryWeightUnitsPrefs extends WarehouseWeightUnitsPrefsNotifier {
  @override
  WeightUnitsPrefs build() => const WeightUnitsPrefs();

  @override
  void persist() {}
}

class _Row extends EditableGridRow {
  _Row({this.params, double? kg, String qty = ''})
    : weight = WeightEntryController(kg: kg) {
    this.qty.text = qty;
  }

  final WeightEntryController weight;
  final UtenAutofillTextController qty = UtenAutofillTextController(
    autofilled: false,
  );
  WeightParams? params;

  double? get qtyBase => double.tryParse(qty.text.trim());

  @override
  void dispose() {
    weight.dispose();
    qty.dispose();
    super.dispose();
  }
}

/// 金样 S18 供应商 A: 单重约 2.0 g, 可参考。
const _learned = WeightParams(
  key: 'g1|',
  goodsId: 'g1',
  basis: WeightBasis.learned,
  logMean: -6.214979467174846,
  lotPrior: 3.869930380683166e-05,
  df: 15,
  tier: WeightTier.yellow,
  nInliers: 12,
  tolerancePct: 3,
);

const _red = WeightParams(
  key: 'g1|',
  goodsId: 'g1',
  basis: WeightBasis.learned,
  logMean: -6.214979467174846,
  lotPrior: 0.01,
  df: 4,
  tier: WeightTier.red,
  nInliers: 1,
);

const _exactKg = WeightParams(
  key: 'g2|',
  goodsId: 'g2',
  basis: WeightBasis.exact,
  massFactorKg: 1,
);

Future<UtenEditableGridController<_Row>> _pump(
  WidgetTester tester,
  List<_Row> rows, {
  WeightCaptureMode mode = WeightCaptureMode.inbound,
  bool autofill = false,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = UtenEditableGridController<_Row>(initial: rows);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        warehouseWeightUnitsPrefsProvider.overrideWith(
          _MemoryWeightUnitsPrefs.new,
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final units = ref.watch(warehouseWeightUnitsPrefsProvider);
              return ListView(
                children: [
                  UtenEditableGrid<_Row>(
                    controller: controller,
                    showAddRow: false,
                    selectable: true,
                    showRowDelete: false,
                    showColumnSettings: false,
                    toolbarActions: const [WeightEntryUnitButton()],
                    columns: [
                      EditableGridColumn<_Row>(
                        key: 'qty',
                        label: '数量',
                        width: 120,
                        cellBuilder: (context, row) => TextField(
                          key: const ValueKey('qty-input'),
                          controller: row.qty,
                        ),
                      ),
                      weightGridColumn<_Row>(
                        controllerOf: (r) => r.weight,
                        entryUnit: units.entry,
                        mode: mode,
                        paramsOf: (r) => r.params,
                        qtyBaseOf: (r) => r.qtyBase,
                        qtyListenableOf: (r) => r.qty,
                        baseUnitNameOf: (_) => '个',
                        qtyAutofill: autofill
                            ? WeightQtyAutofill<_Row>(
                                qtyControllerOf: (r) => r.qty,
                              )
                            : null,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Finder get _inputs => find.byKey(const ValueKey('weight-cell-input'));

TextField _input(WidgetTester tester, [int index = 0]) =>
    tester.widget<TextField>(_inputs.at(index));

UtenFieldHintIcon? _status(WidgetTester tester) {
  final f = find.byKey(const ValueKey('weight-cell-status'));
  if (f.evaluate().isEmpty) return null;
  return tester.widget<UtenFieldHintIcon>(f.first);
}

void main() {
  testWidgets('带后缀输入换成千克, 失焦后规范成列单位', (tester) async {
    final row = _Row();
    await _pump(tester, [row]);

    await tester.enterText(_inputs.first, '850g');
    await tester.pump();
    expect(row.weight.kg, 0.85);
    expect(row.weight.text.text, '850g');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(row.weight.text.text, '0.85');
    expect(row.weight.kg, 0.85);

    await tester.enterText(_inputs.first, '1..2');
    await tester.pump();
    expect(row.weight.kg, isNull);
    expect(row.weight.hasError, isTrue);
    expect(_status(tester)?.errorMessage, weightInputErrorText);

    // 0 = 没称。
    await tester.enterText(_inputs.first, '0');
    await tester.pump();
    expect(row.weight.kg, isNull);
    expect(row.weight.hasError, isFalse);
  });

  testWidgets('勾选多行后改一行重量, 其它勾选行不变 (永不批量)', (tester) async {
    final a = _Row();
    final b = _Row();
    final controller = await _pump(tester, [a, b]);
    controller.setSelected([a, b], true);
    await tester.pump();
    expect(controller.selectedCount, 2);

    await tester.enterText(_inputs.at(0), '12');
    await tester.pump();

    expect(a.weight.kg, 12);
    expect(b.weight.kg, isNull);
    expect(b.weight.text.text, isEmpty);
  });

  testWidgets('货品按重量计: 只读「=25 kg」, 没有输入框', (tester) async {
    final row = _Row(params: _exactKg, qty: '25');
    await _pump(tester, [row]);

    expect(find.text('=25 kg'), findsOneWidget);
    expect(_inputs, findsNothing);

    // 数量变了, 精确重量跟着变。
    row.qty.text = '30';
    await tester.pump();
    expect(find.text('=30 kg'), findsOneWidget);
  });

  testWidgets('占位: 入库「约」、出库「应称」、未学准「可选」', (tester) async {
    await _pump(tester, [_Row(params: _learned, qty: '10000')]);
    expect(_input(tester).decoration!.hintText, '约 19.993');

    await _pump(tester, [
      _Row(params: _learned, qty: '10000'),
    ], mode: WeightCaptureMode.outbound);
    expect(_input(tester).decoration!.hintText, '应称 19.993');

    await _pump(tester, [_Row(params: _red, qty: '10000')]);
    expect(_input(tester).decoration!.hintText, '可选');

    await _pump(tester, [_Row(qty: '10000')]);
    expect(_input(tester).decoration!.hintText, '可选');
  });

  testWidgets('偏差: ALERT 红 ⓘ / WARN 琥珀 ⓘ / 正常只给说明', (tester) async {
    final row = _Row(params: _learned, qty: '10000');
    await _pump(tester, [row]);

    await tester.enterText(_inputs.first, '18.5');
    await tester.pump();
    var status = _status(tester)!;
    expect(status.errorMessage, contains('比登记少约'));
    expect(status.errorMessage, contains('个'));

    await tester.enterText(_inputs.first, '19.3');
    await tester.pump();
    status = _status(tester)!;
    expect(status.errorMessage, isNull);
    expect(status.autofillMessage, contains('比登记少约'));
    expect(status.autofillMessage, contains('(-3.5%)'));

    await tester.enterText(_inputs.first, '20');
    await tester.pump();
    status = _status(tester)!;
    expect(status.errorMessage, isNull);
    expect(status.autofillMessage, isNull);
    expect(status.info, contains('依据: 近12次称重'));
  });

  testWidgets('单重未学准: 不核对, 提示去称样', (tester) async {
    final row = _Row(params: _red, qty: '10000');
    await _pump(tester, [row]);

    await tester.enterText(_inputs.first, '18.5');
    await tester.pump();
    final status = _status(tester)!;
    expect(status.errorMessage, isNull);
    expect(status.autofillMessage, isNull);
    expect(status.info, weightNotLearnedHint);
  });

  testWidgets('数量空着: 称重推算数量 (黄框), 改数量不恢复学习, 改重量才清标记', (tester) async {
    final row = _Row(params: _learned);
    await _pump(tester, [row], mode: WeightCaptureMode.count, autofill: true);

    await tester.enterText(_inputs.first, '20');
    await tester.pump();
    // 20 kg / 2.0 g ≈ 10003.7 -> 按件取整 10004。
    expect(row.qty.text, '10004');
    expect(row.qty.autofilled, isTrue);
    expect(row.weight.qtyFromWeight, isTrue);
    expect(row.weight.qtyEstimateNote, startsWith('按称重推算 '));
    expect(row.weight.canonicalKeyPart, '20|1');

    // 重量再变: 仍是称重预填的数量 -> 跟着重算。
    await tester.enterText(_inputs.first, '10');
    await tester.pump();
    expect(row.qty.text, '5002');
    expect(row.weight.qtyFromWeight, isTrue);

    // 用户改数量: 黄框消失, 但这行仍不参与学习。
    await tester.enterText(find.byKey(const ValueKey('qty-input')), '5000');
    await tester.pump();
    expect(row.qty.autofilled, isFalse);
    expect(row.weight.qtyFromWeight, isTrue);

    // 再改重量: 数量是用户填的, 不动; 标记清掉。
    await tester.enterText(_inputs.first, '11');
    await tester.pump();
    expect(row.qty.text, '5000');
    expect(row.weight.qtyFromWeight, isFalse);
  });

  testWidgets('未学准时不推算数量', (tester) async {
    final row = _Row(params: _red);
    await _pump(tester, [row], mode: WeightCaptureMode.count, autofill: true);

    await tester.enterText(_inputs.first, '20');
    await tester.pump();
    expect(row.qty.text, isEmpty);
    expect(row.weight.qtyFromWeight, isFalse);
  });

  testWidgets('工具条切换称重单位: 表头与已填文本换单位, 千克值不变', (tester) async {
    final row = _Row(kg: 0.85);
    await _pump(tester, [row]);
    expect(find.text('实称重量(kg)'), findsOneWidget);
    expect(row.weight.text.text, '0.85');

    await tester.tap(find.byKey(const ValueKey('weight-entry-unit-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weight-unit-option-克')));
    await tester.pumpAndSettle();

    expect(find.text('实称重量(g)'), findsOneWidget);
    expect(row.weight.unit, WeightUnit.g);
    expect(row.weight.text.text, '850');
    expect(row.weight.kg, 0.85);

    // 新单位下不带后缀的输入按克理解。
    await tester.enterText(_inputs.first, '1200');
    await tester.pump();
    expect(row.weight.kg, 1.2);
  });

  test('表尾偏差行计数: 按称重改过数量的行不算', () {
    final warn = _Row(params: _learned, qty: '10000', kg: 19.3);
    final ok = _Row(params: _learned, qty: '10000', kg: 20);
    final derived = _Row(params: _learned, qty: '10000', kg: 18.5)
      ..weight.qtyFromWeight = true;
    addTearDown(() {
      for (final r in [warn, ok, derived]) {
        r.dispose();
      }
    });
    expect(
      weightDeviationRowCount<_Row>(
        [warn, ok, derived],
        controllerOf: (r) => r.weight,
        paramsOf: (r) => r.params,
        qtyBaseOf: (r) => r.qtyBase,
      ),
      1,
    );
    expect(WeightPredictor.defaultTolerancePct, 3);
  });
}
