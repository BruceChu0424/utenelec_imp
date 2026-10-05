import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_order_progress.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_order_progress.dart';

// ADR-143 §4.6：委外订货单详情的全链路进度 = 每个委外任务一条时间线
// (下单 → 财务审批 → 领料发外 → 加工回厂 → 品质检验 → 仓库确认入仓 → 结案核销)
// + 与委外任务详情同列的直属物料表。节点状态与说明都由服务端给出。

const _timelineKeys = [
  ('ORDER', '下单'),
  ('FINANCE', '财务审批'),
  ('DRAW', '领料发外'),
  ('RETURN', '加工回厂'),
  ('QUALITY', '品质检验'),
  ('STOCK_IN', '仓库确认入仓'),
  ('CLOSE', '结案核销'),
];

Map<String, dynamic> _material({
  required String planItemId,
  required String goodsName,
  required String goodsCode,
  required num requiredQty,
  required num sentQty,
  required num pendingQty,
  required num availableQty,
  required num drawableQty,
  required num shortQty,
  required String state,
  List<Map<String, dynamic>> supplySources = const [],
}) => {
  'planItemId': planItemId,
  'lineNo': 1,
  'goodsId': 'goods-$planItemId',
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'colorName': '黑',
  'unitName': '个',
  'perUnitQty': 2,
  'requiredQty': requiredQty,
  'sentQty': sentQty,
  'pendingQty': pendingQty,
  'availableQty': availableQty,
  'drawableQty': drawableQty,
  'shortQty': shortQty,
  'usableQty': sentQty,
  'state': state,
  'supplySources': supplySources,
};

Map<String, dynamic> _approvedProgress({
  required String drawDetail,
  bool priceMasked = false,
}) => {
  'orderId': 'order-1',
  'billNo': 'WD-001',
  'status': 1,
  'financeCaseStatus': 'APPROVED',
  'planStatus': 'OPEN',
  'items': [
    {
      'orderItemId': 'item-1',
      'lineNo': 1,
      'goodsCode': 'FG-01',
      'goodsName': '喷涂外壳',
      'colorName': '黑',
      'unitName': '件',
      'orderQty': 100,
      'materialMode': 'DRAW',
      'drawOpen': true,
      'materialKindCount': 2,
      'readyKindCount': 1,
      'drawnQty': 40,
      'pendingQty': 10,
      'drawableQty': 20,
      'shortQty': 30,
      'returnableQty': 40,
      'receivedQty': 30,
      'qualifiedQty': 28,
      'pendingInspectionQty': 2,
      'stockedQty': 20,
      'settledLossQty': 0,
      'materials': [
        _material(
          planItemId: 'plan-a',
          goodsName: '外壳毛坯',
          goodsCode: 'A-01',
          requiredQty: 200,
          sentQty: 80,
          pendingQty: 20,
          availableQty: 100,
          drawableQty: 0,
          shortQty: 0,
          state: 'DRAWABLE',
        ),
        _material(
          planItemId: 'plan-b',
          goodsName: '油漆',
          goodsCode: 'B-01',
          requiredQty: 200,
          sentQty: 80,
          pendingQty: 20,
          availableQty: 40,
          drawableQty: 40,
          shortQty: 60,
          state: 'SHORT',
          supplySources: [
            {
              'kind': 'PURCHASE',
              'docId': 'po-1',
              'docNo': 'PO-001',
              'openQty': 60,
            },
          ],
        ),
      ],
      'timeline': [
        for (final (key, label) in _timelineKeys)
          {
            'key': key,
            'label': label,
            'state': switch (key) {
              'ORDER' || 'FINANCE' => 'DONE',
              'DRAW' || 'RETURN' || 'QUALITY' || 'STOCK_IN' => 'ACTIVE',
              _ => 'PENDING',
            },
            'detail': switch (key) {
              'DRAW' => drawDetail,
              'RETURN' => '已回厂 30/100 件，委外商处物料可做 40 件',
              'QUALITY' => '合格 28 件，待检 2 件',
              'STOCK_IN' => '已入仓 20 件，待确认 8 件',
              'ORDER' => '订货 100 件',
              'FINANCE' => '财务已批准',
              _ => null,
            },
          },
      ],
    },
  ],
  'issues': [
    {
      'id': 'issue-1',
      'billNo': 'WL-001',
      'status': 0,
      'warehouseName': '原料仓',
      'totalQty': 120,
    },
  ],
  'receipts': [
    {
      'id': 'receipt-1',
      'billNo': 'WJ-001',
      'status': 1,
      'totalQty': 30,
      'iqcStatus': 'RESOLVED',
      'warehouseStockInStatus': 'PARTIAL_STOCK_IN',
      'iqcPassedBaseQty': 28,
      'warehouseStockedBaseQty': 20,
      'pendingStockInBaseQty': 8,
    },
    {
      'id': 'receipt-2',
      'billNo': 'WJ-002',
      'status': 1,
      'totalQty': 5,
      'iqcStatus': 'RESOLVED',
    },
  ],
  'wastes': [
    {'id': 'waste-1', 'billNo': 'SH-001', 'status': 1, 'deductAmount': 12.5},
  ],
  'apPostedTotal': priceMasked ? null : 880,
  'priceMasked': priceMasked,
};

class _ProgressRepository extends SubcontractRepository {
  _ProgressRepository(this.payloads)
    : super(ApiClient(Dio()), SubcontractDocType.order);

  final List<Map<String, dynamic>> payloads;
  int calls = 0;

  @override
  Future<SubcontractOrderProgress> orderProgress(String id) async {
    final payload =
        payloads[calls < payloads.length ? calls : payloads.length - 1];
    calls++;
    return SubcontractOrderProgress.fromJson(payload);
  }
}

Future<void> _pumpSection(
  WidgetTester tester,
  _ProgressRepository repository,
) async {
  tester.view.physicalSize = const Size(2600, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(
          body: SingleChildScrollView(
            child: SubcontractOrderProgressSection(orderId: 'order-1'),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subcontractRepositoryProvider(
          SubcontractDocType.order,
        ).overrideWithValue(repository),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('每个委外任务一条时间线：领料发外显示已领 x/Q，节点按服务端顺序排开', (tester) async {
    final repository = _ProgressRepository([
      _approvedProgress(drawDetail: '已领 40/100 件，待仓库发 10 件，可领 20 件，还缺 30 件'),
      _approvedProgress(drawDetail: '已领 70/100 件，还缺 30 件'),
    ]);
    await _pumpSection(tester, repository);

    double left(String key) => tester
        .getTopLeft(
          find.byKey(ValueKey('subcontract-progress-node-item-1-$key')),
        )
        .dx;
    for (var i = 1; i < _timelineKeys.length; i++) {
      expect(
        left(_timelineKeys[i].$1),
        greaterThan(left(_timelineKeys[i - 1].$1)),
        reason: _timelineKeys[i].$2,
      );
    }
    for (final (_, label) in _timelineKeys) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('已领 40/100 件，待仓库发 10 件，可领 20 件，还缺 30 件'), findsOneWidget);
    expect(find.text('合格 28 件，待检 2 件'), findsOneWidget);
    expect(find.text('喷涂外壳'), findsOneWidget);
    expect(find.text('订货 100 件'), findsWidgets);

    // 旧的前置自制 / 目标件出仓概念全部消失。
    expect(find.text('内部生产'), findsNothing);
    expect(find.textContaining('目标件'), findsNothing);
    expect(find.textContaining('前置'), findsNothing);
    expect(find.text('查看生产安排'), findsNothing);

    await tester.tap(find.byTooltip('刷新进度'));
    await tester.pumpAndSettle();
    expect(repository.calls, 2);
    expect(find.text('已领 70/100 件，还缺 30 件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('物料表与委外任务详情同列，被别的物料卡住的已备物料不显示可领', (tester) async {
    await _pumpSection(
      tester,
      _ProgressRepository([_approvedProgress(drawDetail: '已领 40/100 件')]),
    );

    expect(
      find.byKey(const ValueKey('subcontract-progress-materials-item-1')),
      findsOneWidget,
    );
    for (final header in [
      '物料名称',
      '每套用量',
      '需求',
      '已发外',
      '待仓库发',
      '仓库可用',
      '本次可领',
      '还缺',
      '供应来源',
      '状态',
    ]) {
      expect(find.text(header), findsWidgets, reason: header);
    }
    expect(find.text('直属物料 · 已备 1/2 种'), findsOneWidget);
    expect(find.text('外壳毛坯'), findsOneWidget);
    expect(find.text('油漆'), findsOneWidget);
    expect(find.text('已备'), findsOneWidget);
    expect(find.text('缺料'), findsOneWidget);
    expect(find.text('采购在途 60(PO-001)'), findsOneWidget);
    // 与任务详情同一规则：不缺的物料来源列是「—」，只有还缺且没有在途才是「未安排」。
    expect(find.text('未安排'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('领料出仓单显示待仓库发料且不合计不同物料；入仓状态缺失时不推断已入仓', (tester) async {
    await _pumpSection(
      tester,
      _ProgressRepository([_approvedProgress(drawDetail: '已领 40/100 件')]),
    );

    expect(find.text('领料出仓单'), findsOneWidget);
    expect(find.text('WL-001 · 原料仓'), findsOneWidget);
    expect(find.text('待仓库发料'), findsOneWidget);
    expect(
      find.text('质检已结案 · 仓库部分入库 · 合格 28 · 已入库 20 · 待入库 8'),
      findsOneWidget,
    );
    expect(find.text('质检已结案 · 仓库入库状态待回传'), findsOneWidget);
    expect(find.text('仓库已确认入仓'), findsNothing);
    expect(find.text('应付摘要'), findsOneWidget);
    expect(find.text('建议索赔 12.50'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端屏蔽金额时不显示应付摘要与建议索赔', (tester) async {
    await _pumpSection(
      tester,
      _ProgressRepository([
        _approvedProgress(drawDetail: '已领 40/100 件', priceMasked: true),
      ]),
    );

    expect(find.text('应付摘要'), findsNothing);
    expect(find.textContaining('建议索赔'), findsNothing);
    expect(find.text('WJ-001 · 30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺 BOM 的委外件在草稿订货单上标出并显示服务端说明', (tester) async {
    await _pumpSection(
      tester,
      _ProgressRepository([
        {
          'orderId': 'order-1',
          'status': 0,
          'items': [
            {
              'orderItemId': 'item-9',
              'goodsCode': 'FG-09',
              'goodsName': '组装件',
              'unitName': '套',
              'orderQty': 5,
              'materialMode': 'MISSING_BOM',
              'materials': <Map<String, dynamic>>[],
              'timeline': [
                {'key': 'ORDER', 'label': '下单', 'state': 'DONE'},
                {
                  'key': 'FINANCE',
                  'label': '财务审批',
                  'state': 'ACTIVE',
                  'detail': '待提交财务审核',
                },
                {
                  'key': 'DRAW',
                  'label': '领料发外',
                  'state': 'ACTIVE',
                  'detail': '委外件还没有维护 BOM(直属物料)，研发完善后才能提交财务',
                },
              ],
            },
          ],
          'priceMasked': true,
        },
      ]),
    );

    expect(find.text('缺 BOM'), findsOneWidget);
    expect(find.text('委外件还没有维护 BOM(直属物料)，研发完善后才能提交财务'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('subcontract-progress-materials-item-9')),
      findsNothing,
    );
    expect(find.textContaining('自备料'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
