// 到货登记「实称重量」契约 (ADR-135 §3.1):
//  1. 重量列跟在数量组(本次实收, 单位内联 2026-10-10 T9)之后, 表头随录入单位「实称重量(kg)」;
//  2. 带单位后缀输入(20g) 以千克 4 位提交, 幂等键带上重量: 改了重量是另一个请求;
//  3. 按本单供应商学到的单重核对, 偏差超出容差出「称重核对」标签, 表尾「实称 / 称重偏差」;
//  4. 行单位本身是重量单位时只读「=5 kg」, 提交不带重量;
//  5. 称重计数「按称重改数量」回填完整估算数量(黄框)并带 qtyFromWeight。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_autofill_text_controller.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/warehouse/pages/inbound_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_autofill_text_field.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inbound_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_place_suggestion_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

import 'arrival_weight_test_support.dart';
import 'inbound_arrival_test_support.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../helpers/warehouse_request_scope_fixture.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';

const _goodsId = 'goods-screw';
const _captureFeedback = bool.fromEnvironment('UTEN_CAPTURE_FEEDBACK');
final _feedbackCaptureKey = GlobalKey();
const _itemId = 'order-item-screw';

ProcurementReceiptPrefill _prefill({
  String? unitId,
  String unitName = '个',
  num approvedRemainingQty = 5,
  ProcurementInboundOrderType orderType =
      ProcurementInboundOrderType.subcontract,
}) => ProcurementReceiptPrefill(
  expectationId: 'expectation-weight',
  orderType: orderType,
  purchaserId: orderType == ProcurementInboundOrderType.purchase
      ? 'emp-me'
      : null,
  orderBillNo: 'SC-PO-WEIGHT',
  supplierId: 'supplier-1',
  supplierName: '测试委外商',
  warehouseId: 'warehouse-1',
  suggestedWarehouseId: 'warehouse-1',
  items: [
    ProcurementReceiptPrefillItem(
      orderItemId: _itemId,
      goodsId: _goodsId,
      goodsCode: 'SCR-01',
      goodsName: '螺丝',
      unitId: unitId,
      unitName: unitName,
      unitRate: 1,
      approvedRemainingQty: approvedRemainingQty,
    ),
  ],
);

Future<({_Api api, FakeWeightRepository weights})> _open(
  WidgetTester tester, {
  required ProcurementReceiptPrefill prefill,
  Map<String, WeightUnit> massUnits = const {},
  bool failFirstArrival = false,
  String actualQty = '5',
}) async {
  tester.view.physicalSize = const Size(2200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_captureFeedback) await loadAuditScreenshotFonts(tester);
  final api = _Api(prefill: prefill, failFirstArrival: failFirstArrival);
  final weights = FakeWeightRepository(
    api,
    byGoods: const {_goodsId: learnedTwoGramParams},
  );
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('任务中心')),
      GoRoute(
        path: '/receipt',
        // ADR-151 §5：单张 = 1 个来源的同一个登记页，按来源 id 从服务端读预计到货。
        builder: (_, _) => const InboundArrivalRegistrationPage(
          expectationIds: ['expectation-weight'],
          canRegister: true,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(IdleWarehouseTestSnapshot.new),
        apiClientProvider.overrideWithValue(api),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.warehouseInboundView,
          Perm.warehouseInboundStockIn,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        ...warehouseWeightTestOverrides(
          api,
          repository: weights,
          massUnits: massUnits,
        ),
        employeeRepositoryProvider.overrideWithValue(
          DioEmployeeRepository(api),
        ),
        procurementInboundRepositoryProvider.overrideWithValue(
          DioProcurementInboundRepository(api),
        ),
        warehousePlaceSuggestionRepositoryProvider.overrideWithValue(
          WarehousePlaceSuggestionRepository(api),
        ),
        departmentCodeIdMapProvider.overrideWith(
          (ref) async => <String, String>{},
        ),
      ],
      child: RepaintBoundary(
        key: _feedbackCaptureKey,
        child: MaterialApp.router(
          routerConfig: router,
          theme: _captureFeedback
              ? auditScreenshotTheme(buildLightTheme())
              : null,
        ),
      ),
    ),
  );
  router.push<void>('/receipt');
  await tester.pumpAndSettle();
  if (prefill.orderType == ProcurementInboundOrderType.subcontract) {
    // Receiving records an operator's physical count; a material capacity is
    // never an actual receipt. The weight cases start after counting 5 units.
    await tester.enterText(
      find.byKey(const ValueKey('warehouse-arrival-qty-$_itemId')),
      actualQty,
    );
    await tester.pumpAndSettle();
  }
  return (api: api, weights: weights);
}

Finder _grid() => find.byKey(const Key('warehouse-arrival-lines-grid'));

Finder _weightInput() => find.descendant(
  of: _grid(),
  matching: find.byKey(const ValueKey('weight-cell-input')),
);

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.text('先质检后入库'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认登记送检'));
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Map<String, dynamic> _item(Map<String, dynamic> body) =>
    (body['lines'] as List).cast<Map<String, dynamic>>().single;

void main() {
  testWidgets('采购到货快速改收费量和赠品仍按实物数量换算，恢复草稿保留单重原文', (tester) async {
    await _open(
      tester,
      prefill: _prefill(orderType: ProcurementInboundOrderType.purchase),
    );
    final unitInput = find.byKey(const ValueKey('unit-weight-cell-input'));
    await tester.enterText(unitInput, '2.125g');
    final qtyInput = find.byKey(
      const ValueKey('warehouse-arrival-qty-$_itemId'),
    );
    final giftInput = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '赠品数量',
    );
    for (var i = 1; i <= 20; i++) {
      await tester.enterText(qtyInput, i.toString());
      await tester.enterText(giftInput, '1');
    }
    await tester.pump();
    expect(
      tester.widget<TextField>(_weightInput()).controller!.text,
      '0.044625',
    );
    final editor =
        tester.state(find.byType(InboundArrivalRegistrationPage))
            as FormDraftMixin<InboundArrivalRegistrationPage>;
    final draft = editor.captureFormDraft();
    await editor.restoreFormDraft(draft);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(unitInput).controller!.text, '2.125g');
    expect(
      tester.widget<TextField>(_weightInput()).controller!.text,
      '0.044625',
    );
  });

  testWidgets('单重逐字输入小数与单位后缀不丢原文或光标', (tester) async {
    await _open(tester, prefill: _prefill());
    final input = find.byKey(const ValueKey('unit-weight-cell-input'));
    await tester.showKeyboard(input);
    for (final raw in [
      '-',
      '1',
      '1.',
      '1.2',
      '0',
      '0.',
      '0.5',
      '0.5k',
      '0.5kg',
    ]) {
      tester.testTextInput.enterText(raw);
      await tester.pump();
      final controller = tester.widget<TextField>(input).controller!;
      expect(controller.text, raw);
      expect(controller.selection.baseOffset, raw.length);
    }
    expect(tester.widget<TextField>(_weightInput()).controller!.text, '2.5');
  });

  testWidgets('到货个重与总重双向换算，数量变化及草稿恢复后提交同一精确总重', (tester) async {
    final (:api, weights: _) = await _open(tester, prefill: _prefill());
    final unitInput = find.byKey(const ValueKey('unit-weight-cell-input'));
    await tester.enterText(unitInput, '2g');
    await tester.pump();
    expect(tester.widget<TextField>(_weightInput()).controller!.text, '0.01');
    final qty = find.byKey(const ValueKey('warehouse-arrival-qty-$_itemId'));
    await tester.enterText(qty, '4');
    await tester.pump();
    expect(tester.widget<TextField>(_weightInput()).controller!.text, '0.008');
    final editor =
        tester.state(find.byType(InboundArrivalRegistrationPage))
            as FormDraftMixin<InboundArrivalRegistrationPage>;
    final draft = editor.captureFormDraft();
    await editor.restoreFormDraft(draft);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(unitInput).controller!.text, '2g');
    await tester.enterText(_weightInput(), '12g');
    await tester.pump();
    expect(tester.widget<TextField>(unitInput).controller!.text, '3');
    if (_captureFeedback) {
      await saveAuditScreenshot(
        tester,
        _feedbackCaptureKey,
        'internal-feedback-unit-weight',
      );
    }
    await _submit(tester);
    expect(_item(api.arrivalBodies.single)['weight'], '0.012');
  });

  testWidgets('个重错误输入不被当作没称而提交', (tester) async {
    final (:api, weights: _) = await _open(tester, prefill: _prefill());
    await tester.enterText(
      find.byKey(const ValueKey('unit-weight-cell-input')),
      'bad',
    );
    await tester.pump();
    await tester.tap(find.text('先质检后入库'));
    await tester.pumpAndSettle();
    expect(api.arrivalBodies, isEmpty);
    expect(find.text('确认登记送检'), findsNothing);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('unit-weight-cell-input')),
          )
          .controller!
          .text,
      'bad',
    );
  });

  testWidgets('旧中断草稿保留原请求形状与重试键，不补发独立资料写请求', (tester) async {
    final (:api, :weights) = await _open(
      tester,
      prefill: _prefill(),
      failFirstArrival: true,
    );
    final editor =
        tester.state(find.byType(InboundArrivalRegistrationPage))
            as FormDraftMixin<InboundArrivalRegistrationPage>;
    final oldDraft = editor.captureFormDraft()
      ..remove('profileLearningInCommand');
    await editor.restoreFormDraft(oldDraft);
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(api.arrivalBodies, hasLength(1));
    expect(_item(api.arrivalBodies.first).containsKey('goodsProfile'), isFalse);
    final originalKey = api.arrivalBodies.first['idempotencyKey'];
    await _submit(tester);
    expect(api.arrivalBodies, hasLength(2));
    expect(api.arrivalBodies.last['idempotencyKey'], originalKey);
    expect(_item(api.arrivalBodies.last).containsKey('goodsProfile'), isFalse);
  });

  testWidgets('资料学习随本次实际登记行提交，修改学习值是不同登记内容', (tester) async {
    final (:api, :weights) = await _open(
      tester,
      prefill: _prefill(),
      failFirstArrival: true,
    );
    final series = find.byWidgetPredicate(
      (widget) =>
          widget is WarehouseAutofillTextField && widget.hintText == '物料系列',
    );
    expect(series, findsOneWidget);
    final seriesController = tester
        .widget<WarehouseAutofillTextField>(series)
        .controller;
    expect(seriesController.text, isEmpty);
    final seriesInput = find.descendant(
      of: series,
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(seriesInput).controller,
      same(seriesController),
    );
    expect(tester.widget<TextField>(seriesInput).decoration?.hintText, '物料系列');
    final editor =
        tester.state(find.byType(InboundArrivalRegistrationPage))
            as FormDraftMixin<InboundArrivalRegistrationPage>;
    await _submit(tester);
    final originalKey = api.arrivalBodies.first['idempotencyKey'];
    expect(_item(api.arrivalBodies.first)['goodsProfile'], {
      'goodsCode': 'SCR-01',
    });
    final changed = editor.captureFormDraft();
    (changed['rows'] as List).cast<Map<String, dynamic>>().single['series'] =
        '新系列';
    await editor.restoreFormDraft(changed);
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(api.arrivalBodies, hasLength(2));
    expect(api.arrivalBodies.last['idempotencyKey'], isNot(originalKey));
    expect(_item(api.arrivalBodies.last)['goodsProfile'], {
      'goodsCode': 'SCR-01',
      'series': '新系列',
    });
    expect(
      (_item(api.arrivalBodies.last)['goodsProfile'] as Map).containsKey(
        'goodsId',
      ),
      isFalse,
    );
  });

  testWidgets('历史单重实际预填，但未经实称的建议不提交为重量', (tester) async {
    final (:api, :weights) = await _open(tester, prefill: _prefill());
    expect(
      tester.widget<TextField>(_weightInput()).controller!.text,
      '0.009996287001961856',
    );
    // 预填建议 = 全站黄框待核对口径（不再有「≈」前缀与格下小字）。
    final decoration = tester.widget<TextField>(_weightInput()).decoration!;
    expect(decoration, isA<UtenInputDecoration>());
    expect((decoration as UtenInputDecoration).autofilled, isTrue);
    expect(weights.requests.single.single.warehouseId, 'warehouse-1');
    expect(weights.requests.single.single.colorId, isNull);
    await _submit(tester);
    expect(_item(api.arrivalBodies.single).containsKey('weight'), isFalse);
    expect(
      _item(api.arrivalBodies.single).containsKey('qtyFromWeight'),
      isFalse,
    );
    expect(_item(api.arrivalBodies.single)['qty'], '5');
  });

  testWidgets('实称重量: 后缀换千克提交, 幂等键带重量, 偏差出称重核对标签', (tester) async {
    final (:api, :weights) = await _open(
      tester,
      prefill: _prefill(),
      failFirstArrival: true,
    );

    // 实称重量和单重相邻，按原数量分组后核对称重并选入库仓。
    final grid = tester.widget<UtenEditableGrid<EditableGridRow>>(_grid());
    final labels = grid.columns.map((column) => column.label).toList();
    final qty = labels.indexOf('本次实收');
    expect(labels.sublist(qty, qty + 7), [
      '本次实收',
      '赠品数量',
      '实物数量',
      '实称重量(kg)',
      '单重(g)',
      '称重核对',
      '入库仓库',
    ]);
    expect(labels.contains('单位'), isFalse);
    // 只读数量列单位内联；录入列单位挂输入框尾部。
    expect(
      grid.columns.singleWhere((column) => column.key == 'physicalQty').label,
      '实物数量',
    );
    final totals = find.byKey(const Key('warehouse-arrival-totals'));
    final footerText = find
        .descendant(of: totals, matching: find.byType(Text))
        .evaluate()
        .toSet();
    // The shared footer also renders received/physical totals with units. Check
    // the two actual row cells without counting those independent summaries.
    expect(
      find
          .descendant(of: _grid(), matching: find.text('5 个'))
          .evaluate()
          .where((element) => !footerText.contains(element)),
      hasLength(2),
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('warehouse-arrival-qty-$_itemId')),
          )
          .decoration!
          .suffixText,
      '个',
    );
    // 单重参数按「货品 × 本单供应商」取。
    expect(weights.requests.first.single.goodsId, _goodsId);
    expect(weights.requests.first.single.supplierId, 'supplier-1');

    // 5 个 × 约 2 g = 约 10 g; 称了 20 g → 偏多约 5 个, 出琥珀/红标签。
    await tester.enterText(_weightInput(), '20g');
    await tester.pump();
    final chip = find.byKey(
      const ValueKey('warehouse-arrival-weight-check-$_itemId'),
    );
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.textContaining('偏多约')),
      findsOneWidget,
    );
    // 表尾: 实称 20 g, 称重偏差 1 行。
    expect(
      find.descendant(of: totals, matching: find.text('20 g')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: totals, matching: find.text('1 行')),
      findsWidgets,
    );

    // 第一次提交丢响应: 重量以千克 4 位提交, 没按称重改数量不带标记。
    await _submit(tester);
    expect(api.arrivalBodies, hasLength(1));
    final first = api.arrivalBodies.single;
    expect(_item(first)['weight'], '0.02');
    expect(_item(first)['qty'], '5');
    expect(_item(first).containsKey('qtyFromWeight'), isFalse);

    // 改了重量再提交是另一个请求 (幂等键不同)。
    await tester.enterText(_weightInput(), '19g');
    await tester.pump();
    await _submit(tester);
    expect(api.arrivalBodies, hasLength(2));
    final second = api.arrivalBodies.last;
    expect(_item(second)['weight'], '0.019');
    expect(second['idempotencyKey'], isNot(first['idempotencyKey']));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('任务中心'), findsOneWidget);
  });

  testWidgets('行单位本身是重量单位: 只读「=5 kg」, 提交不带重量', (tester) async {
    final (:api, weights: _) = await _open(
      tester,
      prefill: _prefill(unitId: 'unit-kg', unitName: 'kg'),
      massUnits: const {'unit-kg': WeightUnit.kg},
    );

    expect(
      find.descendant(
        of: _grid(),
        matching: find.byKey(const ValueKey('weight-cell-exact')),
      ),
      findsOneWidget,
    );
    expect(find.text('=5 kg'), findsOneWidget);
    expect(_weightInput(), findsNothing);

    await _submit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(api.arrivalBodies, hasLength(1));
    expect(_item(api.arrivalBodies.single).containsKey('weight'), isFalse);
  });

  testWidgets('称重计数「按称重改数量」: 数量黄框回填并带 qtyFromWeight', (tester) async {
    final (:api, weights: _) = await _open(
      tester,
      prefill: _prefill(approvedRemainingQty: 10000),
      actualQty: '10000',
    );

    await tester.ensureVisible(find.byKey(const ValueKey('weight-cell-weigh')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: _grid(),
        matching: find.byKey(const ValueKey('weight-cell-weigh')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('weigh-count-gross-0')),
      '19.3',
    );
    await tester.pumpAndSettle();
    // 到货默认「只记重量」; 次按钮「按称重改数量」按估算数量入账。
    await tester.tap(find.byKey(const ValueKey('weigh-count-secondary')));
    await tester.pumpAndSettle();

    final qtyField = tester.widget<TextField>(
      find.byKey(const ValueKey('warehouse-arrival-qty-$_itemId')),
    );
    final qty = qtyField.controller! as UtenAutofillTextController;
    expect(qty.text, '9653.584373984168');
    expect(qty.autofilled, isTrue);

    await _submit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    final item = _item(api.arrivalBodies.single);
    expect(item['qty'], '9653.584373984168');
    expect(item['weight'], '19.3');
    expect(item['qtyFromWeight'], isTrue);
  });

  testWidgets('ADR-144 采购明细显示「最多可收(含允许超收 p%)」，委外不显示该列', (tester) async {
    await _open(
      tester,
      prefill: const ProcurementReceiptPrefill(
        // 合一登记页按来源 id 读预计到货(_open 打开的是 expectation-weight)。
        expectationId: 'expectation-weight',
        orderType: ProcurementInboundOrderType.purchase,
        orderBillNo: 'PO-TOLERANCE',
        supplierId: 'supplier-1',
        supplierName: '测试供应商',
        warehouseId: 'warehouse-1',
        suggestedWarehouseId: 'warehouse-1',
        items: [
          ProcurementReceiptPrefillItem(
            orderItemId: _itemId,
            goodsId: _goodsId,
            goodsCode: 'SCR-01',
            goodsName: '螺丝',
            unitName: '个',
            unitRate: 1,
            approvedRemainingQty: 5,
            allowedOverReceiptPct: 5,
            maxReceivableQty: 5.25,
          ),
        ],
      ),
    );
    final grid = tester.widget<UtenEditableGrid<EditableGridRow>>(_grid());
    final labels = grid.columns.map((column) => column.label).toList();
    expect(labels.indexOf('最多可收'), labels.indexOf('批准剩余') + 1);
    // 单位内联(2026-10-10 T9)。「超过最多可收的部分才转财务」的常驻提示行已删，
    // 口径钉在列头说明(ADR-144)。
    expect(find.text('5.25 个(含允许超收 5%)'), findsOneWidget);
    expect(
      grid.columns
          .where((column) => column.key == 'maxReceivableQty')
          .single
          .headerInfo,
      contains('超过最多可收的部分才转财务'),
    );
  });

  testWidgets('ADR-144 委外登记不显示「最多可收」列', (tester) async {
    await _open(tester, prefill: _prefill());
    final grid = tester.widget<UtenEditableGrid<EditableGridRow>>(_grid());
    expect(
      grid.columns.where((column) => column.key == 'maxReceivableQty'),
      isEmpty,
    );
    expect(find.textContaining('超过最多可收的部分才转财务'), findsNothing);
  });
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-me',
      code: 'USR-ME',
      name: '仓管员',
      employeeId: 'emp-me',
    ),
  );
}

class _Api extends ApiClient {
  _Api({required this.prefill, this.failFirstArrival = false}) : super(Dio());

  final ProcurementReceiptPrefill prefill;
  final bool failFirstArrival;
  final List<Map<String, dynamic>> arrivalBodies = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => throw ApiException('TEST_UNEXPECTED_GET', path);

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/business-references/warehouses') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓', 'selectableForNew': true},
      ];
    }
    if (path == arrivalExpectationsByIdsPath) {
      return expectationsByIdsAnswer(query, [prefill]);
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == arrivalBatchPath) {
      final request = Map<String, dynamic>.from(body! as Map);
      arrivalBodies.add(request);
      if (failFirstArrival && arrivalBodies.length == 1) {
        throw NetworkException('响应中断，请使用原请求重试');
      }
      return arrivalBatchAnswer(request);
    }
    if (path == '/warehouse/place-suggestions') {
      return const {'items': <Map<String, dynamic>>[]};
    }
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }
}
