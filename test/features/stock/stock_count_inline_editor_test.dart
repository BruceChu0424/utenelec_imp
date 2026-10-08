import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/repositories/stock_count_request_repository.dart';
import 'package:uten_imp/features/stock/counts/widgets/stock_count_inline_editor.dart';
import 'package:uten_imp/features/stock/models/stock_query.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_bin_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import 'instant_inventory_test_fixture.dart';
import '../warehouse/workshop_material_test_support.dart';

const _normal = StockCountWarehouse(
  id: 'leaf-a',
  name: '原料仓 A',
  kind: 'NORMAL',
  reviewRoute: 'FINANCE',
);
const _workshop = StockCountWarehouse(
  id: 'bin1',
  name: '注塑车间内料仓',
  kind: 'WORKSHOP',
  reviewRoute: 'WAREHOUSE',
);
const _screw = '11111111-1111-1111-1111-111111111111';
CountStockRow _row(
  String goodsId, {
  String qty = '0',
  String? weight,
  String? factor,
  bool estimated = false,
}) => CountStockRow(
  goodsId: goodsId,
  goodsName: goodsId == _screw
      ? '螺丝'
      : goodsId == 'pp'
      ? 'PP 颗粒'
      : '零库存物料',
  goodsCode: goodsId,
  categoryId: 'raw',
  unitId: 'unit-1',
  unitName: factor == null ? '个' : '克',
  qty: qty,
  weightKg: weight,
  kgPerBaseUnit: factor,
  weightEstimated: estimated,
  goodsVersion: 7,
  allowedActions: const ['EDIT'],
);

class _CountRepo extends StockCountRequestRepository {
  _CountRepo() : super(ApiClient(Dio()));
  List<CountStockRow> result = [];
  List<StockCountWarehouse> warehouses = const [_normal, _workshop];
  int failures = 0;
  final candidateWarehouses = <String>[];
  final submissions =
      <
        ({
          String warehouse,
          List<Map<String, dynamic>> lines,
          String key,
          String reason,
        })
      >[];
  Future<PagedResult<CountStockRow>> Function(String, List<String>)? deferred;
  @override
  Future<List<ProductCategoryNode>> candidateCategories(
    String warehouseId,
  ) async => [
    ProductCategoryNode(
      id: 'raw',
      code: '',
      name: '原材料',
      level: 0,
      children: [],
    ),
  ];
  @override
  Future<StockCountScope> scope({String? warehouseId}) async => StockCountScope(
    warehouses: warehouses
        .where((w) => warehouseId == null || w.id == warehouseId)
        .toList(),
    allowedActions: const ['SUBMIT'],
  );
  @override
  Future<PagedResult<CountStockRow>> candidates({
    required String warehouseId,
    String? keyword,
    String? categoryId,
    List<String> goodsIds = const [],
    bool stockedOnly = false,
    int page = 1,
    int size = 50,
  }) async {
    candidateWarehouses.add(warehouseId);
    if (deferred != null) return deferred!(warehouseId, goodsIds);
    final rows = result
        .where((r) => goodsIds.isEmpty || goodsIds.contains(r.goodsId))
        .where((r) => !stockedOnly || (double.tryParse(r.qty) ?? 0) != 0)
        .toList();
    return PagedResult(
      items: rows,
      page: 1,
      size: size,
      total: rows.length,
      totalPages: 1,
    );
  }

  @override
  Future<StockCountRequest> submit({
    required String warehouseId,
    required String reason,
    required String idempotencyKey,
    required List<Map<String, dynamic>> lines,
  }) async {
    submissions.add((
      warehouse: warehouseId,
      lines: lines,
      key: idempotencyKey,
      reason: reason,
    ));
    if (failures-- > 0) throw ApiException('NETWORK', '暂未确认结果');
    return StockCountRequest(
      id: 'request-1',
      requestNo: 'PD-1',
      warehouseId: warehouseId,
      warehouseName: '目标仓',
      reviewRoute: warehouseId == 'bin1' ? 'WAREHOUSE' : 'FINANCE',
      status: 'PENDING',
      version: 0,
    );
  }
}

Future<void> _mountInstant(
  WidgetTester tester,
  _CountRepo repo, {
  bool allowed = true,
  InstantInventoryApiFixture? api,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view
    ..physicalSize = const Size(2200, 1200)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(
          api ??
              InstantInventoryApiFixture(
                withTotals: false,
                withAnalysis: false,
              ),
        ),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue({
          if (allowed) stockCountSubmitPermission,
        }),
        stockCountRequestRepositoryProvider.overrideWithValue(repo),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: InstantInventoryPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'exact quantity text and unknown weight survive submit; failed retry is idempotent',
    () async {
      final repo = _CountRepo()..failures = 1;
      final editor = StockCountInlineController(repo)..begin(_normal);
      addTearDown(editor.dispose);
      editor.add(_row('precise', qty: '99999999999999.9998'));
      editor.rows['precise|']!.qty.text = '99999999999999.9999';
      editor.reason.text = '期初清点';
      await expectLater(editor.submit(), throwsA(isA<ApiException>()));
      expect(editor.rows['precise|']!.qty.text, '99999999999999.9999');
      await editor.submit();
      expect(repo.submissions[0].key, repo.submissions[1].key);
      final payload = repo.submissions.last.lines.single;
      expect(payload['expectedQty'], '99999999999999.9998');
      expect(payload['targetQty'], '99999999999999.9999');
      expect(payload['expectedWeightKg'], isNull);
      expect(payload['weightChanged'], false);
      expect(payload.containsKey('targetWeightKg'), isFalse);
      expect(editor.rows['precise|']!.snapshot.qty, '99999999999999.9998');
    },
  );

  test(
    'blank explanation is submitted as empty text and a failed send keeps input for the same key',
    () async {
      final repo = _CountRepo()..failures = 1;
      final editor = StockCountInlineController(repo)..begin(_normal);
      addTearDown(editor.dispose);
      editor.add(_row('blank', qty: '3'));
      editor.rows['blank|']!.qty.text = '4';
      editor.reason.text = '   ';
      await expectLater(editor.submit(), throwsA(isA<ApiException>()));
      expect(editor.rows['blank|']!.qty.text, '4');
      await editor.submit();
      expect(repo.submissions.map((s) => s.reason), ['', '']);
      expect(repo.submissions[0].key, repo.submissions[1].key);
    },
  );

  test(
    'mass quantity derives HALF_UP 4-place kilograms and blocks a positive amount rounded to zero',
    () {
      final mass = StockCountEditRow(
        _row('mass', factor: '0.001000000000'),
        () {},
      );
      addTearDown(mass.dispose);
      mass.qty.text = '3.25';
      expect(mass.targetWeightKg, '0.0033');
      expect(mass.payload(true)['materialSetupBasis'], 'OWN');
      expect(mass.validation, isNull);
      mass.qty.text = '0.0001';
      expect(mass.targetWeightKg, '0');
      expect(mass.validation, contains('小于 0.0001 kg'));
      mass.qty.text = '1.00001';
      expect(mass.validation, contains('最多 4 位'));
    },
  );

  test(
    'positive stock rejects zero weight and quantity zero can clear stock',
    () {
      final row = StockCountEditRow(
        _row('part', qty: '1', weight: '0.5'),
        () {},
      );
      addTearDown(row.dispose);
      row.weight.text = '0';
      expect(row.changed, true);
      expect(row.payload(false)['targetQty'], '1');
      expect(row.payload(false)['targetWeightKg'], '0');
      expect(row.validation, contains('须大于 0'));
      row.qty.text = '0';
      row.weight.clear();
      expect(row.validation, isNull);
      expect(row.payload(false)['weightChanged'], false);
    },
  );

  test(
    'same estimated weight is not a numeric change; unknown weight can be counted',
    () {
      final estimated = StockCountEditRow(
        _row('part', qty: '2', weight: '0.5', estimated: true),
        () {},
      );
      final unknown = StockCountEditRow(_row('unknown', qty: '2'), () {});
      addTearDown(estimated.dispose);
      addTearDown(unknown.dispose);
      estimated.qty.text = '2.0000';
      estimated.weight.text = '0.5000';
      expect(estimated.changed, false);
      unknown.weight.text = '0.5';
      expect(unknown.weightChanged, true);
      expect(unknown.validation, isNull);
      expect(unknown.payload(false)['expectedWeightKg'], isNull);
      expect(unknown.payload(false)['targetWeightKg'], '0.5');
    },
  );

  test(
    'late snapshot from previous warehouse cannot populate a new count mode',
    () async {
      final delayed = Completer<PagedResult<CountStockRow>>();
      final repo = _CountRepo()
        ..deferred = (warehouse, _) => warehouse == 'leaf-a'
            ? delayed.future
            : Future.value(
                PagedResult(
                  items: [_row('new')],
                  page: 1,
                  size: 100,
                  total: 1,
                  totalPages: 1,
                ),
              );
      final editor = StockCountInlineController(repo)..begin(_normal);
      addTearDown(editor.dispose);
      final first = editor.ensureRows(['old']);
      editor.begin(_workshop);
      await editor.ensureRows(['new']);
      delayed.complete(
        PagedResult(
          items: [_row('old')],
          page: 1,
          size: 100,
          total: 1,
          totalPages: 1,
        ),
      );
      await first;
      expect(editor.rows.keys, ['new|']);
      expect(editor.warehouse!.id, 'bin1');
    },
  );

  testWidgets(
    'instant inventory no longer embeds count columns; entry stays permission gated',
    (tester) async {
      final repo = _CountRepo()
        ..result = [_row(_screw, qty: '10', weight: '1.5')];
      await _mountInstant(tester, repo);
      final table = tester.widget<MasterDataTableView<InstantInventoryRow>>(
        find.byType(MasterDataTableView<InstantInventoryRow>),
      );
      expect(
        table.columns.any((c) => c.key == 'countTargetQty'),
        false,
        reason: '盘点录入已迁独立页，本表恢复纯查询口径',
      );
      expect(table.items.map((r) => r.goodsId), contains(_screw));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'without individually granted submit permission no count button is shown',
    (tester) async {
      await _mountInstant(tester, _CountRepo(), allowed: false);
      expect(find.byKey(const Key('stock-count-mode')), findsNothing);
    },
  );

  testWidgets(
    'empty workshop stock can add an existing material into the same table and submit to warehouse review',
    (tester) async {
      final repo = _CountRepo()..result = [_row('pp', factor: '0.001')];
      final bins = FakeWorkshopMaterialRepository()
        ..settingsResult = const [wmTestWorkshop];
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view
        ..physicalSize = const Size(2000, 1100)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            stockCountRequestRepositoryProvider.overrideWithValue(repo),
            workshopMaterialRepositoryProvider.overrideWithValue(bins),
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentPermissionsProvider.overrideWithValue({
              Perm.workshopMaterialView,
              stockCountSubmitPermission,
            }),
            apiClientProvider.overrideWithValue(
              InstantInventoryApiFixture(
                withTotals: false,
                withAnalysis: false,
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: WorkshopMaterialBinPage(workshopId: 'w1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stock-count-mode')));
      await tester.pumpAndSettle();
      expect(find.text('盘点请选择具体仓库'), findsNothing);
      await tester.tap(find.byKey(const Key('stock-count-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原材料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PP 颗粒'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('goods-picker-multi-confirm')));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<WmPositionRow>>(
        find.byType(MasterDataTableView<WmPositionRow>),
      );
      expect(table.items.single.goodsId, 'pp');
      final qty = find.byKey(const ValueKey('stock-count-qty-pp|'));
      await tester.ensureVisible(qty);
      await tester.enterText(qty, '5000');
      await tester.pumpAndSettle();
      // 2026-10-04 用户原路径: 盘点说明选填, 不填直接「保存并送审」。
      expect(find.text('盘点说明(选填)'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('stock-count-save')));
      await tester.tap(find.byKey(const Key('stock-count-save')));
      await tester.pumpAndSettle();
      expect(repo.submissions.single.reason, '');
      expect(repo.submissions.single.warehouse, 'bin1');
      expect(repo.submissions.single.lines.single['expectedQty'], '0');
      expect(repo.submissions.single.lines.single['targetQty'], '5000');
      expect(repo.submissions.single.lines.single['targetWeightKg'], '5');
      expect(repo.submissions.single.lines.single['materialSetupBasis'], 'OWN');
      expect(repo.candidateWarehouses, everyElement('bin1'));
      expect(tester.takeException(), isNull);
    },
  );
}
