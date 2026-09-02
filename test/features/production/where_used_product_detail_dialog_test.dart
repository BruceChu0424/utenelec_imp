import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/production/widgets/where_used_product_detail_dialog.dart';

class _FakeGoodsRepository extends Fake implements GoodsRepository {
  _FakeGoodsRepository({this.shouldFail = false, this.error});

  final bool shouldFail;
  final Object? error;
  int detailCalls = 0;

  @override
  Future<GoodsDetail> detail(String id) async {
    detailCalls += 1;
    final failure = error;
    if (failure != null) throw failure;
    if (shouldFail) throw StateError('not found');
    return GoodsDetail(
      id: id,
      code: 'CP-001',
      name: '墙壁插座成品',
      categoryName: '插座',
      status: '启用',
      sourceType: '自制',
      model: 'U86',
      spec: '10A',
      material: 'PC',
      colorName: '白色',
      unitName: '只',
      pack: '盒装',
      pieces: 20,
    );
  }
}

const _material = GoodsListItem(
  id: 'material-1',
  code: 'MAT-001',
  name: 'A 螺丝',
);

const _row = <String, dynamic>{
  '__productId': 'product-1',
  'goodsCode': 'CP-001',
  'goodsName': '墙壁插座成品',
  'spec': '10A',
  'categoryName': '插座',
  'sources': '当前 BOM · 新生产需求 · 旧生产快照 · 委外历史证据',
  'bomRelation': '直接使用',
  '__goodsStatus': '启用',
  '__currentBom': true,
  '__currentDirect': true,
  '__currentDirectQty': 2.5,
  'executionSegmentCount': 2,
  '__executionEvidenceCount': 2,
  '__executionSubcontractEvidenceCount': 1,
  '__executionRequiredQty': 20,
  '__executionPerProductMin': 2,
  '__executionPerProductMax': 3,
  '__executionFirstUsed': '2026-07-10',
  '__executionSubcontractSegments': 1,
  '__executionSubcontractRequiredQty': 6,
  'legacyPlanCount': 4,
  '__legacyEvidenceCount': 5,
  '__legacyProductionLineCount': 5,
  'legacyRequiredQty': 10,
  '__legacyDqtyMin': 2.5,
  '__legacyDqtyMax': 3,
  '__legacyIssuedQty': 8,
  '__legacyReturnedQty': 1,
  '__legacyFirstUsed': '2025-01-02',
  'subcontractOrderCount': 1,
  '__subcontractOrderEvidenceCount': 2,
  '__subcontractOrderLineCount': 2,
  '__subcontractRequiredQty': 12,
  '__subcontractUnitQtyMin': 1.5,
  '__subcontractUnitQtyMax': 2,
  'subcontractIssueCount': 1,
  '__subcontractIssueEvidenceCount': 1,
  '__subcontractIssueQty': 9,
  '__subcontractReturnedQty': 2,
  '__subcontractWastedQty': 1,
  '__subcontractFirstUsed': '2024-06-01',
  '__subcontractLastUsed': '2024-06-03',
  'lastUsed': '2026-07-31',
};

Future<void> _pumpLauncher(
  WidgetTester tester,
  _FakeGoodsRepository repository, {
  required Size size,
  required bool canViewGoods,
  required bool canViewStock,
  required ValueChanged<WhereUsedProductDetailResult?> onResult,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [goodsRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  onResult(
                    await showWhereUsedProductDetailDialog(
                      context: context,
                      row: _row,
                      material: _material,
                      historyRangeLabel: '全部历史',
                      canViewGoods: canViewGoods,
                      canViewStock: canViewStock,
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'shows separated relationship sources and current goods, then returns BOM link',
    (tester) async {
      final repository = _FakeGoodsRepository();
      WhereUsedProductDetailResult? result;

      await _pumpLauncher(
        tester,
        repository,
        size: const Size(1200, 900),
        canViewGoods: true,
        canViewStock: true,
        onResult: (value) => result = value,
      );

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('多来源关系详情'), findsOneWidget);
      expect(find.text('全部历史 · A 螺丝(MAT-001)'), findsOneWidget);
      expect(
        find.byKey(const Key('where-used-source-overview')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('where-used-current-bom-section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('where-used-execution-demand-section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('where-used-legacy-production-section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('where-used-subcontract-section')),
        findsOneWidget,
      );
      expect(find.text('直接单套用量'), findsOneWidget);
      expect(find.text('展开需求量'), findsOneWidget);
      expect(find.text('净领料'), findsOneWidget);
      expect(find.text('发料痕迹数量(待核)'), findsOneWidget);
      expect(find.text('退料痕迹数量(待核)'), findsOneWidget);
      expect(find.text('损耗痕迹数量(待核)'), findsOneWidget);
      expect(find.textContaining('旧委外发料迁移数据仍待重导'), findsOneWidget);
      expect(find.textContaining('49,889'), findsNothing);
      expect(find.text('当前产成品资料'), findsOneWidget);
      expect(find.text('自制'), findsOneWidget);
      expect(find.text('U86'), findsOneWidget);
      expect(repository.detailCalls, 1);

      await tester.tap(find.byKey(const Key('where-used-open-bom')));
      await tester.pumpAndSettle();

      expect(result?.link, WhereUsedProductLink.bom);
      expect(result?.productId, 'product-1');
      expect(result?.detail?.name, '墙壁插座成品');
    },
  );

  testWidgets('keeps source history visible when current goods lookup fails', (
    tester,
  ) async {
    final repository = _FakeGoodsRepository(shouldFail: true);

    await _pumpLauncher(
      tester,
      repository,
      size: const Size(1200, 900),
      canViewGoods: true,
      canViewStock: false,
      onResult: (_) {},
    );

    expect(find.text('墙壁插座成品'), findsOneWidget);
    expect(
      find.byKey(const Key('where-used-legacy-production-section')),
      findsOneWidget,
    );
    expect(find.text('当前货品主档加载失败，历史反查结果仍可查看。'), findsOneWidget);
    expect(find.byKey(const Key('where-used-detail-retry')), findsOneWidget);
    expect(
      find.byKey(const Key('where-used-open-stock-movements')),
      findsNothing,
    );

    final retry = find.byKey(const Key('where-used-detail-retry'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(repository.detailCalls, 2);
  });

  testWidgets('maps a backend goods FORBIDDEN to the permission state', (
    tester,
  ) async {
    final repository = _FakeGoodsRepository(
      error: ApiException('FORBIDDEN', '无权查看此货品'),
    );

    await _pumpLauncher(
      tester,
      repository,
      size: const Size(1200, 900),
      canViewGoods: true,
      canViewStock: false,
      onResult: (_) {},
    );

    expect(
      find.byKey(const Key('where-used-legacy-production-section')),
      findsOneWidget,
    );
    expect(find.text('你没有查看当前货品主档和 BOM 的权限。'), findsOneWidget);
    expect(find.byKey(const Key('where-used-detail-retry')), findsNothing);
    expect(repository.detailCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact permission gate skips goods request but keeps stock link',
    (tester) async {
      final repository = _FakeGoodsRepository();
      WhereUsedProductDetailResult? result;

      await _pumpLauncher(
        tester,
        repository,
        size: const Size(390, 844),
        canViewGoods: false,
        canViewStock: true,
        onResult: (value) => result = value,
      );

      expect(find.byType(Dialog), findsNothing);
      expect(
        find.byKey(const Key('where-used-product-detail-dialog')),
        findsOneWidget,
      );
      expect(repository.detailCalls, 0);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(find.text('你没有查看当前货品主档和 BOM 的权限。'), findsOneWidget);
      expect(
        find.byKey(const Key('where-used-open-goods-profile')),
        findsNothing,
      );
      expect(find.byKey(const Key('where-used-open-bom')), findsNothing);
      expect(
        find.byKey(const Key('where-used-open-stock-movements')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('where-used-open-stock-movements')),
      );
      await tester.pumpAndSettle();

      expect(result?.link, WhereUsedProductLink.stockMovements);
      expect(result?.productId, 'product-1');
      expect(result?.detail, isNull);
    },
  );

  testWidgets('844x390 landscape with large text opens without overflow', (
    tester,
  ) async {
    final repository = _FakeGoodsRepository();

    await _pumpLauncher(
      tester,
      repository,
      size: const Size(844, 390),
      canViewGoods: true,
      canViewStock: true,
      onResult: (_) {},
      textScale: 1.5,
    );

    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.byKey(const Key('where-used-product-detail-dialog')),
      findsOneWidget,
    );
    expect(repository.detailCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
