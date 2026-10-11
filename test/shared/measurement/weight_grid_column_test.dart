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
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
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
  goodsId: 'g1',
  basis: WeightBasis.learned,
  logMean: -6.214979467174846,
  lotPrior: 0.01,
  df: 4,
  tier: WeightTier.red,
  nInliers: 1,
);

const _exactKg = WeightParams(
  goodsId: 'g2',
  basis: WeightBasis.exact,
  massFactorKg: 1,
);

const _stock = WeightParams(
  goodsId: 'g1',
  stockBalance: WeightStockBalance(
    warehouseId: 'w1',
    qtyBase: 1000,
    weightKg: 20,
  ),
);

Future<UtenEditableGridController<_Row>> _pump(
  WidgetTester tester,
  List<_Row> rows, {
  WeightCaptureMode mode = WeightCaptureMode.inbound,
  bool autofill = false,
  ValueNotifier<WeightParams?>? paramsNotifier,
  bool enabled = true,
  bool weighButton = false,
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
                        paramsOf: (r) => paramsNotifier?.value ?? r.params,
                        paramsListenable: paramsNotifier,
                        enabledOf: (_) => enabled,
                        onWeighCount: weighButton ? (_, _) async {} : null,
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

String? _tooltip(WidgetTester tester) => tester
    .widgetList<Tooltip>(
      find.ancestor(of: _inputs.first, matching: find.byType(Tooltip)),
    )
    .firstOrNull
    ?.message;

String? _cellMessage(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('weight-cell-message'));
  return finder.evaluate().isEmpty
      ? null
      : tester.widget<UtenFieldMessage>(finder.first).message;
}

/// 预填建议态的口径 (2026-10-10 起): 不再有「≈」前缀和格下「预估 · 请填实称」
/// 小字，改为全站预填黄框 + ⓘ (UtenInputDecoration.autofilled)。
void _expectSuggestedDecoration(WidgetTester tester) {
  final decoration = _input(tester).decoration!;
  expect(decoration, isA<UtenInputDecoration>());
  expect((decoration as UtenInputDecoration).autofilled, isTrue);
}

void main() {
  test('建议值切换单位和规范文本不变实称，人工接管后不再覆盖', () {
    final c = WeightEntryController();
    addTearDown(c.dispose);
    c.setSuggestedKg(20, source: '库存');
    expect(c.text.text, '20');
    expect(c.displayKg, 20);
    expect(c.kg, isNull);
    expect(c.canonicalKeyPart, '|0');
    c.switchUnit(WeightUnit.g);
    c.normalize();
    expect(c.text.text, '20000');
    expect(c.kg, isNull);
    c.setSuggestedKg(10);
    expect(c.text.text, '10000');
    c.text.text = '9500';
    c.setSuggestedKg(30);
    expect(c.kg, 9.5);
    expect(c.suggestedKg, isNull);
    expect(c.text.text, '9500');
  });

  test('显式清空与恢复的实称不被后到建议覆盖', () {
    final c = WeightEntryController(kg: 12);
    addTearDown(c.dispose);
    c.setSuggestedKg(20);
    expect(c.text.text, '12');
    c.text.clear();
    c.setSuggestedKg(20);
    expect(c.text.text, isEmpty);
    final fresh = WeightEntryController();
    addTearDown(fresh.dispose);
    fresh.setSuggestedKg(20);
    fresh.text.clear();
    fresh.setSuggestedKg(30);
    expect(fresh.text.text, isEmpty);
    expect(fresh.kg, isNull);
    expect(fresh.canonicalKeyPart, '|0');
  });

  test('人工明确输入同一建议数字才转换为实称，非法建议不会出现', () {
    final c = WeightEntryController();
    addTearDown(c.dispose);
    for (final value in [double.nan, double.infinity, -1.0, 0.0]) {
      c.setSuggestedKg(value);
      expect(c.text.text, isEmpty);
    }
    c.setSuggestedKg(20);
    c.acceptUserInput();
    expect(c.kg, 20);
    expect(c.isSuggested, isFalse);
    expect(c.canonicalKeyPart, '20|0');
  });

  testWidgets('库存1000个20kg：实际预填随数量变化，输入1kg出现黄框文字', (tester) async {
    final row = _Row(params: _stock, qty: '1000');
    await _pump(tester, [row], mode: WeightCaptureMode.outbound);
    expect(row.weight.text.text, '20');
    expect(row.weight.kg, isNull);
    expect(_tooltip(tester), contains('库存数量与重量比例'));
    row.qty.text = '500';
    await tester.pumpAndSettle();
    expect(row.weight.text.text, '10');
    row.qty.text = '0';
    await tester.pumpAndSettle();
    expect(row.weight.text.text, isEmpty);
    row.qty.text = '1000';
    await tester.pumpAndSettle();
    await tester.enterText(_inputs.first, '1');
    await tester.pump();
    expect(_cellMessage(tester), '数值可能有问题');
    expect(_input(tester).decoration!.errorText, isNull);
    expect(_tooltip(tester), contains('预计 20 kg'));
    expect(_tooltip(tester), contains('-95.0%'));
    row.qty.text = '500';
    await tester.pumpAndSettle();
    expect(row.weight.text.text, '1');
    expect(row.weight.kg, 1);
    expect(
      weightDeviationRowCount(
        [row],
        controllerOf: (r) => r.weight,
        paramsOf: (r) => r.params,
        qtyBaseOf: (r) => r.qtyBase,
        mode: WeightCaptureMode.outbound,
      ),
      1,
    );
  });

  testWidgets('真实表格150像素重量列带称重按钮，黄框预填与偏差提示均在格内完整布局', (tester) async {
    final row = _Row(params: _stock, qty: '1000');
    await _pump(
      tester,
      [row],
      mode: WeightCaptureMode.outbound,
      weighButton: true,
    );
    _expectSuggestedDecoration(tester);
    expect(find.byKey(const ValueKey('weight-cell-suggestion')), findsNothing);
    await tester.enterText(_inputs.first, '1');
    await tester.pumpAndSettle();
    final warning = find.text('数值可能有问题');
    expect(warning, findsOneWidget);
    final fieldRect = tester.getRect(
      find.byKey(const ValueKey('weight-cell-content')),
    );
    final warningRect = tester.getRect(warning);
    expect(warningRect.bottom, lessThanOrEqualTo(fieldRect.bottom));
    expect(warningRect.right, lessThanOrEqualTo(fieldRect.right));
    expect(warningRect.left, greaterThanOrEqualTo(fieldRect.left));
    expect(fieldRect.height, lessThan(100));
    expect(find.byKey(const ValueKey('weight-cell-weigh')), findsOneWidget);
    expect(find.byKey(const ValueKey('weight-cell-status')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('异步参数只更新当前数量的建议，不盖住已输入实称', (tester) async {
    final params = ValueNotifier<WeightParams?>(null);
    addTearDown(params.dispose);
    final row = _Row(qty: '1000');
    await _pump(
      tester,
      [row],
      mode: WeightCaptureMode.outbound,
      paramsNotifier: params,
    );
    expect(row.weight.text.text, isEmpty);
    params.value = _stock;
    row.qty.text = '500';
    await tester.pumpAndSettle();
    expect(row.weight.text.text, '10');
    await tester.enterText(_inputs.first, '9.8');
    params.value = _learned;
    await tester.pumpAndSettle();
    expect(row.weight.kg, 9.8);
    expect(row.weight.text.text, '9.8');
  });

  testWidgets('禁用行和未有数量行不预填，卸载时排队同步不触发异常', (tester) async {
    final row = _Row(params: _stock, qty: '1000');
    await _pump(
      tester,
      [row],
      enabled: false,
      mode: WeightCaptureMode.outbound,
    );
    expect(row.weight.text.text, isEmpty);
    final emptyQty = _Row(params: _stock);
    await _pump(tester, [emptyQty], mode: WeightCaptureMode.outbound);
    expect(emptyQty.weight.text.text, isEmpty);
    emptyQty.qty.text = '1000';
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  test(
    'formula weight facts stay kilograms across suffixes unit changes and clearing',
    () {
      final row = _Row();
      addTearDown(row.dispose);
      final column = weightGridColumn<_Row>(
        controllerOf: (row) => row.weight,
        entryUnit: WeightUnit.g,
      );
      final observed = <String?>[];
      void capture() => observed.add(column.exactValueOf!(row));
      final changes = column.exactListenableOf!(row)!;
      changes.addListener(capture);
      row.weight.text.text = '850g';
      expect(column.exactValueOf!(row), '0.85');
      expect(observed.last, '0.85');
      row.weight.switchUnit(WeightUnit.g);
      expect(row.weight.text.text, '850');
      expect(column.exactValueOf!(row), '0.85');
      row.weight.text.clear();
      expect(column.exactValueOf!(row), isNull);
      expect(observed.last, isNull);
      changes.removeListener(capture);
    },
  );

  test(
    'formula weight follows exact quantity and parameter changes without inventing learned weights',
    () {
      final row = _Row(kg: 7, qty: '25');
      final params = ValueNotifier<WeightParams?>(_exactKg);
      addTearDown(row.dispose);
      addTearDown(params.dispose);
      final column = weightGridColumn<_Row>(
        controllerOf: (row) => row.weight,
        entryUnit: WeightUnit.g,
        paramsOf: (_) => params.value,
        paramsListenable: params,
        qtyBaseOf: (row) => row.qtyBase,
        qtyListenableOf: (row) => row.qty,
      );
      final observed = <String?>[];
      void capture() => observed.add(column.exactValueOf!(row));
      final changes = column.exactListenableOf!(row)!;
      changes.addListener(capture);
      expect(column.exactValueOf!(row), '25.0');
      row.qty.text = '26.0001';
      expect(observed.last, '26.0001');
      params.value = _learned;
      expect(observed.last, '7.0');
      row.weight.text.text = 'invalid';
      expect(observed.last, isNull);
      changes.removeListener(capture);
    },
  );

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
    expect(_cellMessage(tester), weightInputErrorText);
    expect(find.byKey(const ValueKey('weight-cell-status')), findsNothing);

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

  testWidgets('输入首字符后焦点保持：说明出现不重建输入框（不再要点第二次）', (tester) async {
    // 2026-10-10 根因修复回归锁：外层 Tooltip 曾按「有/无说明」切换包裹结构，
    // 第一击键让说明从无到有，TextField 元素被废弃重建、焦点丢失，用户必须
    // 再点一次才能继续输。结构恒定后焦点必须全程保持。
    final row = _Row(params: _stock, qty: '1000');
    await _pump(tester, [row], mode: WeightCaptureMode.outbound);
    await tester.enterText(_inputs.first, '1');
    await tester.pump();
    final focusNode = _input(tester).focusNode;
    expect(focusNode, isNotNull);
    expect(focusNode!.hasFocus, isTrue, reason: '首个字符击键后焦点仍在重量格');
    await tester.enterText(_inputs.first, '12');
    await tester.pump();
    expect(_input(tester).focusNode!.hasFocus, isTrue);
    expect(row.weight.text.text, '12');
    // 清空回说明消失态再输入，结构反向切换同样不得丢焦点。
    await tester.enterText(_inputs.first, '');
    await tester.pump();
    await tester.enterText(_inputs.first, '3');
    await tester.pump();
    expect(_input(tester).focusNode!.hasFocus, isTrue);
    expect(row.weight.kg, 3);
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

  testWidgets('可信单重实际预填且黄框待核对，未学准保持可选空值', (tester) async {
    final inbound = _Row(params: _learned, qty: '10000');
    await _pump(tester, [inbound]);
    expect(inbound.weight.text.text, '19.9926');
    expect(inbound.weight.kg, isNull);
    expect(inbound.weight.isSuggested, isTrue);
    _expectSuggestedDecoration(tester);
    expect(_tooltip(tester), contains('尚未实称'));

    await _pump(tester, [
      _Row(params: _learned, qty: '10000'),
    ], mode: WeightCaptureMode.outbound);
    expect(_input(tester).decoration!.hintText, '应称 19.993');

    await _pump(tester, [_Row(params: _red, qty: '10000')]);
    expect(_input(tester).decoration!.hintText, '可选');
    expect(_input(tester).controller!.text, isEmpty);

    await _pump(tester, [_Row(qty: '10000')]);
    expect(_input(tester).decoration!.hintText, '可选');
  });

  testWidgets('所有统计偏差均黄框文字提醒，正常只有悬停说明，无单元格提示图标', (tester) async {
    final row = _Row(params: _learned, qty: '10000');
    await _pump(tester, [row]);

    await tester.enterText(_inputs.first, '18.5');
    await tester.pump();
    expect(_input(tester).decoration!.errorText, isNull);
    expect(_cellMessage(tester), '数值可能有问题');
    expect(_tooltip(tester), contains('比登记少约'));
    expect(
      _input(tester).decoration!.enabledBorder!.borderSide.color,
      weightAlertColor(
        Theme.of(tester.element(_inputs.first)),
        WeightAlertLevel.warn,
      ),
    );
    expect(find.byKey(const ValueKey('weight-cell-status')), findsNothing);

    await tester.enterText(_inputs.first, '19.3');
    await tester.pump();
    expect(_input(tester).decoration!.errorText, isNull);
    expect(_cellMessage(tester), '数值可能有问题');
    expect(_tooltip(tester), contains('(-3.5%)'));

    await tester.enterText(_inputs.first, '20');
    await tester.pump();
    expect(_input(tester).decoration!.errorText, isNull);
    expect(_cellMessage(tester), isNull);
    expect(_tooltip(tester), contains('依据: 近12次称重'));
  });

  testWidgets('单重未学准: 不核对, 提示去称样', (tester) async {
    final row = _Row(params: _red, qty: '10000');
    await _pump(tester, [row]);

    await tester.enterText(_inputs.first, '18.5');
    await tester.pump();
    expect(_input(tester).decoration!.errorText, isNull);
    expect(_cellMessage(tester), isNull);
    expect(_tooltip(tester), weightNotLearnedHint);
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
