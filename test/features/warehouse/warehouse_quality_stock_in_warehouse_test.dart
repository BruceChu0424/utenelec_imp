import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_batch_stock_in_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_merged_table.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_quality_slice_table.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  _registerVisualTests();

  test('draft blocks invalid quantities and missing actual warehouse', () {
    final draft = WarehouseQualitySliceDraft(
      WarehouseQualityReleasedSlice.fromJson(_slice('a', null, 5)),
    );
    addTearDown(draft.dispose);
    expect(draft.validate(), contains('目标叶仓'));
    draft.selectWarehouse(id: 'warehouse-a', name: '塑胶叶仓');
    for (final invalid in ['NaN', 'Infinity', '-1', '0', '0.00001', '5.0001']) {
      draft.quantity.text = invalid;
      expect(draft.validate(), isNotNull, reason: invalid);
    }
    draft.quantity.text = '2.5';
    draft.place.text = ' A-02 ';
    expect(draft.validate(), isNull);
    final first = draft.toConfirmItem();
    expect(first.warehouseId, 'warehouse-a');
    expect(first.place, 'A-02');
    final firstKey = warehouseQualitySliceFingerprint([first]);
    expect(warehouseQualitySliceFingerprint([draft.toConfirmItem()]), firstKey);
    draft.selectWarehouse(id: 'warehouse-b', name: '五金叶仓');
    draft.place.text = 'A-02';
    expect(
      warehouseQualitySliceFingerprint([draft.toConfirmItem()]),
      isNot(firstKey),
    );
  });

  test(
    'refresh preserves selected warehouse but uses fresh remaining ceiling',
    () {
      final old = WarehouseQualitySliceDraft(
        WarehouseQualityReleasedSlice.fromJson(_slice('a', null, 5)),
      )..selectWarehouse(id: 'warehouse-b', name: '五金叶仓');
      old.quantity.text = '4';
      old.place.text = 'B-09';
      final fresh = WarehouseQualitySliceDraft(
        WarehouseQualityReleasedSlice.fromJson(_slice('a', null, 2)),
        snapshot: old.snapshot,
      );
      addTearDown(old.dispose);
      addTearDown(fresh.dispose);
      expect(fresh.warehouseId, 'warehouse-b');
      expect(fresh.quantity.text, '4');
      expect(fresh.place.text, 'B-09');
      expect(fresh.validate(), contains('不得超过合格待入量 2'));
      final unavailable = WarehouseQualitySliceDraft(
        fresh.slice,
        snapshot: old.snapshot,
        canConfirm: false,
      );
      addTearDown(unavailable.dispose);
      expect(unavailable.selected, isFalse);
    },
  );

  test(
    'changing actual warehouse clears its dependent place while same UUID and refresh retain input',
    () {
      final source = WarehouseQualityReleasedSlice.fromJson(
        _slice('a', 'warehouse-a', 5),
      );
      final draft = WarehouseQualitySliceDraft(source);
      addTearDown(draft.dispose);
      expect(draft.place.text, 'A-01');
      expect(draft.selectWarehouse(id: 'warehouse-a', name: '同仓新显示名'), isFalse);
      expect(draft.place.text, 'A-01');

      expect(draft.selectWarehouse(id: 'warehouse-b', name: '五金叶仓'), isTrue);
      expect(draft.place.text, isEmpty);
      expect(draft.placeInputHint, '请重新填写实际库位');
      expect(draft.validate(), contains('目标仓库已更换，请重新填写实际库位'));
      final stillEmpty = WarehouseQualitySliceDraft(
        source,
        snapshot: draft.snapshot,
      );
      addTearDown(stillEmpty.dispose);
      expect(
        stillEmpty.place.text,
        isEmpty,
        reason: 'Refresh must not refill the old warehouse hint',
      );
      expect(stillEmpty.placeInputHint, '请重新填写实际库位');

      draft.place.text = 'B-07';
      expect(draft.validate(), isNull);
      expect(
        draft.selectWarehouse(id: 'warehouse-b', name: '本部库-五金叶仓'),
        isFalse,
      );
      expect(draft.place.text, 'B-07');
      final refreshed = WarehouseQualitySliceDraft(
        source,
        snapshot: draft.snapshot,
      );
      addTearDown(refreshed.dispose);
      expect(refreshed.warehouseId, 'warehouse-b');
      expect(refreshed.place.text, 'B-07');
      expect(refreshed.toConfirmItem().place, 'B-07');
      expect(
        refreshed.selectWarehouse(id: 'warehouse-a', name: '塑胶叶仓'),
        isTrue,
      );
      expect(
        refreshed.place.text,
        isEmpty,
        reason: 'Changing back also requires an explicit place review',
      );
    },
  );

  testWidgets(
    'subcontract with no suggested warehouse can select actual leaves per slice',
    (tester) async {
      final gateway = _Gateway();
      final api = _WarehouseApi();
      await _pump(tester, gateway, api);
      expect(find.byType(WarehouseQualityMergedTable), findsOneWidget);
      expect(find.text('供应商 / 委外商'), findsOneWidget);
      expect(find.text('委外厂甲'), findsNWidgets(2));
      expect(
        api.calls,
        isEmpty,
        reason: 'Preview must not load unrelated master data',
      );

      await tester.tap(
        find.byKey(const Key('warehouse-quality-batch-confirm')),
      );
      await tester.pumpAndSettle();
      expect(
        gateway.commands,
        isEmpty,
        reason: 'Missing warehouse is validated before HTTP',
      );
      expect(find.textContaining('请选择本次实际入库的目标叶仓'), findsWidgets);

      await _pickFirstWarehouse(tester);
      expect(api.calls, ['/master/warehouses/dict']);
      expect(find.text('本部库-塑胶叶仓'), findsOneWidget);
      expect(find.text('目标叶仓已调整，提交时重新核定去向'), findsOneWidget);
      expect(
        gateway.commands,
        isEmpty,
        reason: 'Selecting and previewing do not write stock',
      );
      expect(
        _field(tester, 'quality-slice-place-pass-a').controller!.text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('quality-slice-place-pass-a')),
                matching: find.byType(TextField),
              ),
            )
            .decoration!
            .hintText,
        '请重新填写实际库位',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-batch-confirm')),
      );
      await tester.pumpAndSettle();
      expect(
        gateway.commands,
        isEmpty,
        reason:
            'The old warehouse place cannot be submitted after a warehouse change',
      );
      await tester.enterText(
        find.byKey(const Key('quality-slice-place-pass-a')),
        'SL-02',
      );
      await tester.enterText(
        find.byKey(const Key('quality-slice-qty-pass-a')),
        '3',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-batch-confirm')),
      );
      await tester.pumpAndSettle();

      final batch = gateway.commands.single.batches.single;
      expect(batch.receiptType, 'SUBCONTRACT');
      expect(batch.receiptId, 'receipt-subcontract');
      expect(batch.items.map((item) => item.passEventId), ['pass-a', 'pass-b']);
      expect(batch.items.map((item) => item.warehouseId), [
        'warehouse-a',
        'warehouse-b',
      ]);
      expect(batch.items.map((item) => item.baseQty), [3, 5]);
      expect(batch.items.map((item) => item.place), ['SL-02', 'A-01']);
      expect(batch.items.map((item) => item.expectedRemainingBaseQty), [5, 5]);
    },
  );

  testWidgets(
    'batch conflict refresh keeps actual warehouse and blocks stale quantities',
    (tester) async {
      final gateway = _Gateway(conflictOnce: true);
      await _pump(tester, gateway, _WarehouseApi());
      await _pickFirstWarehouse(tester);
      await tester.enterText(
        find.byKey(const Key('quality-slice-qty-pass-a')),
        '4',
      );
      await tester.enterText(
        find.byKey(const Key('quality-slice-place-pass-a')),
        'B-09',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-batch-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      expect(gateway.detailCalls, 2);
      expect(find.text('本部库-塑胶叶仓'), findsOneWidget);
      expect(_field(tester, 'quality-slice-qty-pass-a').controller!.text, '4');
      expect(
        _field(tester, 'quality-slice-place-pass-a').controller!.text,
        'B-09',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-batch-confirm')),
      );
      await tester.pumpAndSettle();
      expect(
        gateway.commands,
        hasLength(1),
        reason: '4 must not be sent against fresh remaining 2',
      );

      await tester.enterText(
        find.byKey(const Key('quality-slice-qty-pass-a')),
        '2',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-batch-confirm')),
      );
      await tester.pumpAndSettle();
      final second = gateway.commands.last.batches.single;
      expect(second.items.first.expectedRemainingBaseQty, 2);
      expect(second.items.first.warehouseId, 'warehouse-a');
      expect(second.items.first.place, 'B-09');
      expect(
        second.idempotencyKey,
        isNot(gateway.commands.first.batches.single.idempotencyKey),
      );
    },
  );

  testWidgets(
    'readonly batch preview exposes source and quantities without editable controls',
    (tester) async {
      final gateway = _Gateway();
      final api = _WarehouseApi();
      await _pump(tester, gateway, api, canConfirm: false);
      expect(find.byType(WarehouseQualityMergedTable), findsOneWidget);
      expect(find.text('合格待入量'), findsOneWidget);
      expect(find.text('委外厂甲'), findsNWidgets(2));
      expect(find.textContaining('当前为只读预览'), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(
        find.byKey(const Key('warehouse-quality-batch-confirm')),
        findsNothing,
      );
      expect(gateway.commands, isEmpty);
      expect(api.calls, isEmpty);
    },
  );
}

TextFormField _field(WidgetTester tester, String key) =>
    tester.widget<TextFormField>(find.byKey(Key(key)));

void _registerVisualTests() {
  for (final width in [1440.0, 375.0]) {
    for (final single in [true, false]) {
      testWidgets(
        'quality visual ${single ? 'single' : 'batch'} $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          await loadAuditScreenshotFonts(tester);
          final preferences = await SharedPreferences.getInstance();
          final gateway = _Gateway(visualFixture: true);
          final boundary = GlobalKey();
          final prefix =
              'quality-${single ? 'single' : 'batch'}-${width.toInt()}';
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                warehouseQualityResultRepositoryProvider.overrideWithValue(
                  gateway,
                ),
                masterNameServiceProvider.overrideWithValue(
                  MasterNameService(_WarehouseApi()),
                ),
                sharedPreferencesProvider.overrideWithValue(preferences),
                currentPermissionsProvider.overrideWithValue({
                  Perm.warehouseIqcStockInView,
                  Perm.warehouseIqcStockInConfirm,
                }),
                isSuperAdminProvider.overrideWithValue(false),
              ],
              child: RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: auditScreenshotTheme(buildLightTheme()),
                  home: single
                      ? const WarehouseQualityResultDetailPage(
                          receiptType: 'SUBCONTRACT',
                          receiptId: 'receipt-subcontract',
                        )
                      : WarehouseQualityBatchStockInPage(
                          targets: [
                            WarehouseQualityResultTask.fromJson(_detail()),
                          ],
                        ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('quality-slice-qty-pass-pending')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('quality-slice-warehouse-pass-rejected')),
            findsNothing,
          );
          await saveAuditScreenshot(tester, boundary, '$prefix-overview');

          final horizontal = tester.state<ScrollableState>(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.right,
                )
                .first,
          );
          if (width < 600) {
            final quantityField = find.byKey(
              const Key('quality-slice-qty-pass-a'),
            );
            await Scrollable.ensureVisible(
              tester.element(quantityField),
              alignment: 0.5,
            );
            final quantityViewportLeft =
                (horizontal.context.findRenderObject() as RenderBox)
                    .localToGlobal(Offset.zero)
                    .dx;
            final quantityStart =
                horizontal.position.pixels +
                tester.getRect(find.text('合格待入量').first).left -
                quantityViewportLeft -
                50;
            horizontal.position.jumpTo(
              quantityStart
                  .clamp(0, horizontal.position.maxScrollExtent)
                  .toDouble(),
            );
            await tester.pumpAndSettle();
            await saveAuditScreenshot(tester, boundary, '$prefix-quantities');
            final warehouseField = find.byKey(
              const Key('quality-slice-warehouse-pass-a'),
            );
            await Scrollable.ensureVisible(
              tester.element(warehouseField),
              alignment: 0.5,
            );
            final viewportLeft =
                (horizontal.context.findRenderObject() as RenderBox)
                    .localToGlobal(Offset.zero)
                    .dx;
            final locationStart =
                horizontal.position.pixels +
                tester.getRect(warehouseField).left -
                viewportLeft -
                44;
            horizontal.position.jumpTo(
              locationStart
                  .clamp(0, horizontal.position.maxScrollExtent)
                  .toDouble(),
            );
            await tester.pumpAndSettle();
            await saveAuditScreenshot(tester, boundary, '$prefix-locations');
          }

          final vertical = tester.state<ScrollableState>(
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is Scrollable &&
                      widget.axisDirection == AxisDirection.down,
                )
                .first,
          );
          vertical.position.jumpTo(vertical.position.maxScrollExtent);
          await tester.pumpAndSettle();
          await saveAuditScreenshot(tester, boundary, '$prefix-bottom');
          final confirm = find.byKey(
            Key(
              single
                  ? 'warehouse-quality-detail-confirm'
                  : 'warehouse-quality-batch-confirm',
            ),
          );
          final lastField = find.byKey(
            const Key('quality-slice-place-pass-last'),
          );
          expect(
            tester.getRect(lastField).bottom,
            lessThan(tester.getRect(confirm).top),
          );

          vertical.position.jumpTo(0);
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(
            tester.element(
              find.byKey(const Key('quality-slice-warehouse-pass-a')),
            ),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('quality-slice-warehouse-pass-a')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('warehouse-picker-entry-main')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('warehouse-picker-entry-warehouse-a')),
            findsOneWidget,
          );
          await saveAuditScreenshot(tester, boundary, '$prefix-leaf-picker');
          expect(tester.takeException(), isNull);
        },
        skip: !const bool.fromEnvironment('UTEN_CAPTURE_UI'),
      );
    }
  }
}

Future<void> _pickFirstWarehouse(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('quality-slice-warehouse-pass-a')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('warehouse-picker-entry-disabled')),
    findsNothing,
  );
  await tester.tap(find.byKey(const Key('warehouse-picker-entry-main')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('warehouse-picker-entry-disabled')),
    findsNothing,
  );
  await tester.tap(find.byKey(const Key('warehouse-picker-entry-warehouse-a')));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _Gateway gateway,
  _WarehouseApi api, {
  bool canConfirm = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(2400, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        warehouseQualityResultRepositoryProvider.overrideWithValue(gateway),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.warehouseIqcStockInView,
          if (canConfirm) Perm.warehouseIqcStockInConfirm,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        home: WarehouseQualityBatchStockInPage(
          targets: [WarehouseQualityResultTask.fromJson(_detail())],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _WarehouseApi extends ApiClient {
  _WarehouseApi() : super(Dio());
  final calls = <String>[];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add(path);
    if (path != '/master/warehouses/dict') {
      throw StateError('Unexpected master request $path');
    }
    return const [
      {'id': 'main', 'name': '本部库', 'accountable': false},
      {'id': 'warehouse-a', 'name': '塑胶叶仓', 'parentId': 'main'},
      {'id': 'warehouse-b', 'name': '五金叶仓', 'parentId': 'main'},
      {'id': 'disabled', 'name': '停用叶仓', 'parentId': 'main', 'status': '禁用'},
    ];
  }
}

class _Gateway implements WarehouseQualityResultGateway {
  _Gateway({this.conflictOnce = false, this.visualFixture = false});
  final bool conflictOnce;
  final bool visualFixture;
  final commands = <WarehouseQualityBatchConfirmCommand>[];
  int detailCalls = 0;
  double remaining = 5;

  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async {
    detailCalls++;
    return WarehouseQualityResultDetail.fromJson(
      visualFixture ? _visualDetail() : _detail(remaining: remaining),
    );
  }

  @override
  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  ) async {
    commands.add(command);
    if (conflictOnce && commands.length == 1) {
      remaining = 2;
      throw ApiException('CONFLICT', '放行余量已经变化');
    }
    return WarehouseQualityBatchConfirmResult(
      confirmedReceipts: command.batches.length,
      confirmedItemCount: command.batches.expand((batch) => batch.items).length,
      results: const [],
    );
  }

  @override
  Future<int> pendingCount() async => 1;
  @override
  Future<Map<WarehouseIqcStockInReceiptType, int>> typeCounts() async => {};
  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async => {};
  @override
  Future<PagedResult<WarehouseQualityResultTask>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
  }) async => throw StateError('Unexpected list request');
}

Map<String, dynamic> _detail({double remaining = 5}) => {
  'receiptType': 'SUBCONTRACT',
  'receiptId': 'receipt-subcontract',
  'billNo': 'WWRK-001',
  'supplierId': 'supplier-subcontract',
  'supplierName': '委外厂甲',
  'workStatus': 'ALL_PASSED',
  'qualityStatus': 'RESOLVED',
  'completed': false,
  'allowedActions': ['CONFIRM'],
  'pendingSliceCount': 2,
  'items': [_slice('a', null, remaining), _slice('b', 'warehouse-b', 5)],
  'lines': [
    for (final id in ['a', 'b'])
      {
        'inspectionItemId': 'line-$id',
        'goodsId': 'goods-$id',
        'goodsName': '部件$id',
        'unitName': '件',
        'receivedBaseQty': 5,
        'passedBaseQty': 5,
        'failedBaseQty': 0,
        'warehouseStockedBaseQty': 0,
        'pendingStockBaseQty': id == 'a' ? remaining : 5,
        'lineStatus': 'RESOLVED',
      },
  ],
};

Map<String, dynamic> _slice(String id, String? warehouseId, double remaining) =>
    {
      'passEventId': 'pass-$id',
      'inspectionItemId': 'line-$id',
      'goodsId': 'goods-$id',
      'goodsName': '部件$id',
      'unitName': '件',
      'receivedBaseQty': 5,
      'qualityPassedBaseQty': 5,
      'warehouseStockedBaseQty': 0,
      'releasedBaseQty': 5,
      'stockedForReleaseBaseQty': 0,
      'remainingBaseQty': remaining,
      'placeHint': 'A-01',
      'warehouseId': warehouseId,
      'warehouseName': warehouseId == 'warehouse-b' ? '五金叶仓' : null,
    };

Map<String, dynamic> _visualDetail() {
  final detail = _detail();
  final items = <Map<String, dynamic>>[
    for (final row in detail['items'] as List)
      Map<String, dynamic>.from(row as Map),
  ];
  final lines = <Map<String, dynamic>>[
    for (final row in detail['lines'] as List)
      Map<String, dynamic>.from(row as Map),
  ];
  for (final id in [
    'pending',
    'rejected',
    ...List.generate(12, (index) => 'm$index'),
    'last',
  ]) {
    final pending = id == 'pending';
    final rejected = id == 'rejected';
    lines.add({
      'inspectionItemId': 'line-$id',
      'goodsId': 'goods-$id',
      'goodsName': pending
          ? '待检查轴承（只读）'
          : rejected
          ? '不合格壳体（只读）'
          : id == 'last'
          ? '末行连接件'
          : '精密连接部件 $id',
      'goodsCode': 'WL-$id',
      'unitName': '件',
      'receivedBaseQty': 5,
      'passedBaseQty': pending || rejected ? 0 : 5,
      'failedBaseQty': rejected ? 5 : 0,
      'warehouseStockedBaseQty': 0,
      'pendingStockBaseQty': pending || rejected ? 0 : 5,
      'lineStatus': pending ? 'PENDING' : 'RESOLVED',
    });
    if (!pending && !rejected) {
      items.add({
        ..._slice(id, 'warehouse-b', 5),
        'goodsCode': 'WL-$id',
        'goodsName': id == 'last' ? '末行连接件' : '精密连接部件 $id',
      });
    }
  }
  return {
    ...detail,
    'items': items,
    'lines': lines,
    'goodsLineCount': lines.length,
    'passedLineCount': items.length,
    'failedLineCount': 1,
    'openItemCount': 1,
    'pendingSliceCount': items.length,
    'billDate': '2026-09-12',
    'workStatus': 'PARTIAL_PASSED',
    'qualityStatus': 'PARTIAL',
  };
}
