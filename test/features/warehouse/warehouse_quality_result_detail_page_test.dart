import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_return.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_return_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_stock_in_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('inspection line verdict derives from quantities and open status', () {
    WarehouseQualityInspectionLine line(Map<String, dynamic> json) =>
        WarehouseQualityInspectionLine.fromJson(json);

    // 合格：有合格量、无不合格、检验已结案 → 绿色对勾口径。
    expect(
      line(const {
        'inspectionItemId': 'i-1',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 10,
        'failedBaseQty': 0,
        'lineStatus': 'RESOLVED',
      }).verdict,
      WarehouseQualityLineVerdict.passed,
    );
    // 不合格：只有不合格量 → 红色禁止口径。
    expect(
      line(const {
        'inspectionItemId': 'i-2',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 0,
        'failedBaseQty': 10,
        'lineStatus': 'RESOLVED',
      }).verdict,
      WarehouseQualityLineVerdict.rejected,
    );
    // 部分合格：合格 + 不合格（或仍有待检余量）→ 黄色警告口径。
    expect(
      line(const {
        'inspectionItemId': 'i-3',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 6,
        'failedBaseQty': 4,
        'lineStatus': 'RESOLVED',
      }).verdict,
      WarehouseQualityLineVerdict.partial,
    );
    expect(
      line(const {
        'inspectionItemId': 'i-4',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 6,
        'failedBaseQty': 0,
        'lineStatus': 'PARTIAL',
      }).verdict,
      WarehouseQualityLineVerdict.partial,
    );
    // 待检：尚无结论 → 蓝色沙漏口径。
    expect(
      line(const {
        'inspectionItemId': 'i-5',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 0,
        'failedBaseQty': 0,
        'lineStatus': 'PENDING',
      }).verdict,
      WarehouseQualityLineVerdict.waiting,
    );
  });

  testWidgets(
    'merged table joins verdicts and releasable slices with solo-confirm path',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final qualityGateway = _QualityGateway(_detailJson());
      final stockInGateway = _StockInGateway();
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            warehouseQualityResultRepositoryProvider.overrideWithValue(
              qualityGateway,
            ),
            warehouseIqcStockInRepositoryProvider.overrideWithValue(
              stockInGateway,
            ),
            warehouseIqcReturnRepositoryProvider.overrideWithValue(
              _FailingReturnGateway(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseIqcStockInView,
              Perm.warehouseIqcStockInConfirm,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: WarehouseQualityResultDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 单据信息 + 合并明细表（一张表：判定 + 放行切片同场）。
      expect(find.text('PR-001'), findsOneWidget);
      expect(find.text('检查结果与待入库明细'), findsOneWidget);
      // 精确表头（无必填星标）。检验状态列已并入判定结果（2026-09-03 表头清理）。
      for (final header in const [
        '判定结果',
        '货品名称',
        '收货总量',
        '合格总量',
        '不合格总量',
        '放行信息',
      ]) {
        expect(find.text(header), findsOneWidget, reason: '缺列 $header');
      }
      // 必填列表头带红 *（如「货品库位 *」），用包含匹配。
      expect(find.textContaining('货品库位'), findsOneWidget);
      expect(find.textContaining('待入库余量 / 本次实收'), findsOneWidget);
      // 逐行判定（图标旁判定文案始终在场，不只靠颜色）。
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      // 黄色警告图标出现三次：单人兼任提示横幅 + 部分合格判定随 2 个切片行出现。
      expect(find.byIcon(Icons.warning_amber_rounded), findsNWidgets(3));
      expect(find.byIcon(Icons.block), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_top_outlined), findsOneWidget);
      // 合并表按切片行展开：部分合格明细行的判定文案随 2 个切片行出现 2 次。
      expect(find.text('部分合格'), findsNWidgets(2));
      expect(find.text('不合格'), findsOneWidget);
      // 同一明细行拆 2 个放行切片 → 货品列标注「切片 i/2」防误读。
      expect(find.text('切片 1/2'), findsOneWidget);
      expect(find.text('切片 2/2'), findsOneWidget);
      // 可办理行默认全额 + 建议库位预填（底部确认按钮计数 = 切片数）。
      expect(find.text('确认入库(3)'), findsOneWidget);

      // 单人兼任：放行人是本人 → 复核提示在场但不阻断确认按钮。
      expect(
        find.byKey(const Key('warehouse-quality-detail-own-release')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
        findsOneWidget,
      );

      // 确认入库：改一条库位 → 复核弹窗 → 提交单张确认命令（含预填与手填库位）。
      await tester.enterText(
        find.byKey(const Key('quality-slice-place-pass-1')),
        'B-02',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认入库'));
      await tester.pumpAndSettle();

      expect(stockInGateway.confirmCalls, 1);
      final command = stockInGateway.lastCommand!;
      expect(command.idempotencyKey, isNotEmpty);
      expect(command.items.length, 3);
      final byPassEvent = {
        for (final item in command.items) item.passEventId: item,
      };
      expect(byPassEvent['pass-1']!.place, 'B-02');
      expect(byPassEvent['pass-2']!.place, 'A-01');
      expect(byPassEvent['pass-1']!.baseQty, 10);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial confirm conflict preserves merged-table inputs', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final qualityGateway = _QualityGateway(_detailJson());
    final stockInGateway = _StockInGateway(conflictOnce: true);
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseQualityResultRepositoryProvider.overrideWithValue(
            qualityGateway,
          ),
          warehouseIqcStockInRepositoryProvider.overrideWithValue(
            stockInGateway,
          ),
          warehouseIqcReturnRepositoryProvider.overrideWithValue(
            _FailingReturnGateway(),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInView,
            Perm.warehouseIqcStockInConfirm,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: WarehouseQualityResultDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const quantityKey = Key('quality-slice-qty-pass-1');
    const placeKey = Key('quality-slice-place-pass-1');
    await tester.enterText(find.byKey(quantityKey), '3.5');
    await tester.enterText(find.byKey(placeKey), 'B-02');
    await tester.tap(find.byKey(const Key('warehouse-quality-detail-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认入库'));
    await tester.pumpAndSettle();

    // 冲突 → 整批未入库、刷新事实并保留当前输入。
    expect(stockInGateway.confirmCalls, 1);
    expect(qualityGateway.detailCalls, greaterThanOrEqualTo(2));
    final command = stockInGateway.lastCommand!;
    final edited = {
      for (final item in command.items) item.passEventId: item,
    }['pass-1']!;
    expect(edited.baseQty, 3.5);
    expect(edited.place, 'B-02');
    expect(
      tester.widget<TextFormField>(find.byKey(quantityKey)).controller?.text,
      '3.5',
    );
    expect(
      tester.widget<TextFormField>(find.byKey(placeKey)).controller?.text,
      'B-02',
    );
    expect(find.textContaining('已保留当前输入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only permission hides confirm bar and inputs', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseQualityResultRepositoryProvider.overrideWithValue(
            _QualityGateway(_detailJson()),
          ),
          warehouseIqcStockInRepositoryProvider.overrideWithValue(
            _StockInGateway(),
          ),
          warehouseIqcReturnRepositoryProvider.overrideWithValue(
            _FailingReturnGateway(),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionRecordReturn,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: WarehouseQualityResultDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 无确认双权限：不出确认底栏与任何输入/勾选单元，明细表仍只读可见。
    expect(
      find.byKey(const Key('warehouse-quality-detail-confirm')),
      findsNothing,
    );
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    // 合并表按切片行展开：部分合格 ×2 切片 → 判定文案出现 2 次（只读无输入框）。
    expect(find.text('部分合格'), findsNWidgets(2));
    expect(find.text('只读'), findsNothing);
    expect(find.textContaining('当前为只读查看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed receipt keeps merged table read-only with history', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseQualityResultRepositoryProvider.overrideWithValue(
            _QualityGateway(_completedDetailJson()),
          ),
          warehouseIqcStockInRepositoryProvider.overrideWithValue(
            _StockInGateway(),
          ),
          warehouseIqcReturnRepositoryProvider.overrideWithValue(
            _FailingReturnGateway(),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInView,
            Perm.warehouseIqcStockInConfirm,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: WarehouseQualityResultDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 已完结：无待入库切片 → 无勾选/输入/确认；入库历史只读在场。
    expect(
      find.byKey(const Key('warehouse-quality-detail-confirm')),
      findsNothing,
    );
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('实际库位 C-03'), findsOneWidget);
    expect(find.textContaining('仓库员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 四行判定（合格 / 部分合格×2切片 / 不合格 / 待检）+ 三个待入库放行切片。
Map<String, dynamic> _detailJson() => {
  'workStatus': 'ALL_PASSED',
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-08-31',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'qualityStatus': 'RESOLVED',
  'goodsLineCount': 4,
  'passedLineCount': 1,
  'failedLineCount': 2,
  'openItemCount': 1,
  'pendingSliceCount': 3,
  'pendingReturnCount': 0,
  'completed': false,
  'containsOwnRelease': true,
  'allowedActions': <String>['CONFIRM'],
  'lines': [
    for (final (index, verdict) in [
      ('RESOLVED', 10, 10, 0),
      ('RESOLVED', 10, 6, 4),
      ('RESOLVED', 10, 0, 10),
      ('PENDING', 10, 0, 0),
    ].indexed)
      {
        'inspectionItemId': 'inspection-$index',
        'goodsId': 'goods-$index',
        'goodsCode': 'G-00$index',
        'goodsName': '测试产品$index',
        'colorName': null,
        'unitId': 'unit-1',
        'unitName': '件',
        'lineStatus': verdict.$1,
        'receivedBaseQty': verdict.$2,
        'passedBaseQty': verdict.$3,
        'failedBaseQty': verdict.$4,
        'warehouseStockedBaseQty': 0,
        'pendingStockBaseQty': switch (index) {
          0 => 10,
          1 => 6,
          _ => 0,
        },
      },
  ],
  'items': [
    _sliceJson('pass-1', 'inspection-0', 'goods-0', 'G-000', '测试产品0', 10),
    _sliceJson('pass-2', 'inspection-1', 'goods-1', 'G-001', '测试产品1', 3),
    _sliceJson('pass-3', 'inspection-1', 'goods-1', 'G-001', '测试产品1', 3),
  ],
  'history': <Map<String, dynamic>>[],
  'rejections': <Map<String, dynamic>>[],
};

Map<String, dynamic> _sliceJson(
  String passEventId,
  String inspectionItemId,
  String goodsId,
  String goodsCode,
  String goodsName,
  num remaining,
) => {
  'passEventId': passEventId,
  'inspectionItemId': inspectionItemId,
  'goodsId': goodsId,
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'colorName': null,
  'unitId': 'unit-1',
  'unitName': '件',
  'sourceOrderNo': 'PO-001',
  'receivedBaseQty': 10,
  'qualityPassedBaseQty': remaining,
  'warehouseStockedBaseQty': 0,
  'releasedBaseQty': remaining,
  'stockedForReleaseBaseQty': 0,
  'remainingBaseQty': remaining,
  'releasedWeight': null,
  'weightUnitId': null,
  'weightUnitName': null,
  'placeHint': 'A-01',
  'releaseNote': '抽检合格',
  'releasedBy': '当前账号',
  'releasedAt': '2026-08-31T09:00:00Z',
};

/// 已完结：切片全部入库，只余历史。
Map<String, dynamic> _completedDetailJson() => {
  ..._detailJson(),
  'workStatus': 'COMPLETED',
  'pendingSliceCount': 0,
  'completed': true,
  'allowedActions': <String>[],
  'containsOwnRelease': false,
  'items': <Map<String, dynamic>>[],
  'lines': [
    {
      'inspectionItemId': 'inspection-0',
      'goodsId': 'goods-0',
      'goodsCode': 'G-000',
      'goodsName': '测试产品0',
      'colorName': null,
      'unitId': 'unit-1',
      'unitName': '件',
      'lineStatus': 'RESOLVED',
      'receivedBaseQty': 10,
      'passedBaseQty': 10,
      'failedBaseQty': 0,
      'warehouseStockedBaseQty': 10,
      'pendingStockBaseQty': 0,
    },
  ],
  'history': [
    {
      'stockInItemId': 'stock-in-1',
      'batchId': 'batch-1',
      'passEventId': 'pass-1',
      'goodsId': 'goods-0',
      'goodsCode': 'G-000',
      'goodsName': '测试产品0',
      'colorName': null,
      'unitName': '件',
      'baseQty': 10,
      'weight': null,
      'weightUnitName': null,
      'place': 'C-03',
      'confirmedBy': '仓库员',
      'confirmedAt': '2026-08-31T10:30:00Z',
    },
  ],
  'rejections': <Map<String, dynamic>>[],
};

class _QualityGateway implements WarehouseQualityResultGateway {
  _QualityGateway(this.detailJson);

  final Map<String, dynamic> detailJson;
  int detailCalls = 0;

  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async {
    detailCalls++;
    return WarehouseQualityResultDetail.fromJson(detailJson);
  }

  @override
  Future<int> pendingCount() async => 1;

  @override
  Future<Map<WarehouseIqcStockInReceiptType, int>> typeCounts() async =>
      throw StateError('unexpected type counts');

  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
  }) async => throw StateError('unexpected status counts');

  @override
  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  ) async => throw StateError('unexpected batch confirm');

  @override
  Future<PagedResult<WarehouseQualityResultTask>> list({
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
  }) async => throw StateError('unexpected list');
}

class _StockInGateway implements WarehouseIqcStockInGateway {
  _StockInGateway({this.conflictOnce = false});

  final bool conflictOnce;
  int confirmCalls = 0;
  WarehouseIqcStockInConfirmCommand? lastCommand;

  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async {
    confirmCalls++;
    lastCommand = command;
    if (conflictOnce && confirmCalls == 1) {
      throw ApiException('CONFLICT', '品质放行待入库余量已变化');
    }
    return WarehouseIqcStockInConfirmResult(
      batchId: 'batch-1',
      replayed: false,
      confirmedCount: command.items.length,
      confirmedAt: '2026-09-01T10:00:00Z',
    );
  }
}

class _FailingReturnGateway implements WarehouseIqcReturnGateway {
  @override
  Future<WarehouseIqcReturnTask> recordReturn(
    String rejectionId,
    WarehouseIqcRecordReturnCommand command,
  ) async => throw StateError('unexpected record return');
}
