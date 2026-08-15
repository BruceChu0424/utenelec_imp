import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/production/pages/where_used_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _materialId = '11111111-1111-4111-8111-111111111111';
const _productId = '22222222-2222-4222-8222-222222222222';

class _WhereUsedApi extends ApiClient {
  _WhereUsedApi({
    this.reportError,
    this.unattributedDemandCount = 0,
    this.unattributedDemandQty = 0,
  }) : super(Dio());

  final Object? reportError;
  final int unattributedDemandCount;
  final num unattributedDemandQty;

  int materialCalls = 0;
  int reportCalls = 0;
  Map<String, dynamic>? lastMaterialQuery;
  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/reports/where-used/materials') {
      materialCalls += 1;
      lastMaterialQuery = Map<String, dynamic>.of(query ?? const {});
      return <String, dynamic>{
        'items': const [
          {
            'id': _materialId,
            'code': 'MAT-001',
            'name': 'A 螺丝',
            'model': 'M3',
            'spec': '镀锌',
            'status': '启用',
            'sourceType': '外购',
            'categoryName': '原材料',
            'autoCreated': false,
            'deleted': false,
            'currentBom': true,
            'bomIssue': false,
            'productionHistory': true,
            'subcontractHistory': true,
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path != '/production/reports/where-used') {
      throw StateError('unexpected GET $path');
    }
    reportCalls += 1;
    lastQuery = Map<String, dynamic>.of(query ?? const {});
    final error = reportError;
    if (error != null) throw error;
    return <String, dynamic>{
      'columns': const [
        {'key': 'goodsCode', 'label': '产成品编号', 'type': 'text', 'width': 130},
        {'key': 'goodsName', 'label': '产成品名称', 'type': 'text', 'width': 200},
        {'key': 'spec', 'label': '规格', 'type': 'text', 'width': 130},
        {'key': 'categoryName', 'label': '分类', 'type': 'text', 'width': 110},
        {'key': 'sources', 'label': '关系来源', 'type': 'text', 'width': 230},
        {'key': 'bomRelation', 'label': '当前BOM', 'type': 'text', 'width': 105},
      ],
      'rows': const [
        {
          '__productId': _productId,
          '__currentBom': true,
          '__currentDirect': true,
          '__currentDirectQty': 2.5,
          '__goodsStatus': '启用',
          'goodsCode': 'CP-001',
          'goodsName': '墙壁插座成品',
          'spec': '10A',
          'categoryName': '插座',
          'sources': '当前 BOM · 新生产需求 · 旧生产快照 · 委外历史证据',
          'bomRelation': '直接使用',
          'executionSegmentCount': 2,
          '__executionEvidenceCount': 2,
          '__executionSubcontractEvidenceCount': 1,
          '__executionRequiredQty': 20,
          '__executionPerProductMin': 2,
          '__executionPerProductMax': 3,
          '__executionFirstUsed': '2026-07-10',
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
        },
      ],
      'facets': const <String, dynamic>{},
      'meta': {
        'source': 'all',
        'historyDateFiltered': false,
        'unattributedDemandCount': unattributedDemandCount,
        'unattributedDemandQty': unattributedDemandQty,
      },
      'page': 1,
      'size': 50,
      'total': 1,
      'totalPages': 1,
    };
  }
}

class _GoodsRepository extends Fake implements GoodsRepository {
  @override
  Future<GoodsDetail> detail(String id) async => GoodsDetail(
    id: id,
    code: 'CP-001',
    name: '墙壁插座成品',
    categoryName: '插座',
    status: '使用',
    sourceType: '自制',
    spec: '10A',
  );
}

class _BomRepository extends Fake implements GoodsBomRepository {
  final listCalls = <String>[];

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls.add(goodsId);
    return const [];
  }
}

void _configureView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpSimplePage(
  WidgetTester tester,
  _WhereUsedApi api, {
  required Size size,
  double textScale = 1,
}) async {
  _configureView(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {}),
      ],
      child: MaterialApp(
        builder: textScale == 1
            ? null
            : (context, child) {
                final media = MediaQuery.of(context);
                return MediaQuery(
                  data: media.copyWith(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: child!,
                );
              },
        home: const WhereUsedReportPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectMaterial(WidgetTester tester) async {
  await tester.tap(find.text('搜索并选择物料'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('where-used-material-search')),
    'MAT-001',
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  final material = find.byKey(
    const ValueKey('where-used-material-$_materialId'),
  );
  await tester.ensureVisible(material);
  await tester.tap(material);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'result row opens source detail, BOM, and stock link without losing state',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = _WhereUsedApi();
      final goods = _GoodsRepository();
      final bom = _BomRepository();
      final router = GoRouter(
        initialLocation: '/production/where-used',
        routes: [
          GoRoute(
            path: '/production/where-used',
            builder: (_, _) => const WhereUsedReportPage(),
          ),
          // 货品详情整页（与 app_router 同款：?tab= 解析初始页签）。
          GoRoute(
            path: '/basicinfo/goods/:id',
            builder: (_, s) => GoodsDetailPage(
              goodsId: s.pathParameters['id']!,
              initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0,
            ),
          ),
          GoRoute(
            path: '/stock/movement',
            builder: (context, state) => Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  key: const Key('stock-test-back'),
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
              body: Text(
                'stock goodsId=${state.uri.queryParameters['goodsId']}',
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            goodsRepositoryProvider.overrideWithValue(goods),
            goodsBomRepositoryProvider.overrideWithValue(bom),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.goodsView,
              Perm.stockView,
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('搜索并选择物料'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('where-used-material-search')),
        'MAT-001',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(api.materialCalls, greaterThanOrEqualTo(1));
      expect(api.lastMaterialQuery, containsPair('keyword', 'MAT-001'));
      await tester.tap(
        find.byKey(const ValueKey('where-used-material-$_materialId')),
      );
      await tester.pumpAndSettle();

      expect(api.reportCalls, 1);
      expect(api.lastQuery, containsPair('materialGoodsId', _materialId));
      expect(api.lastQuery, containsPair('source', 'all'));
      expect(api.lastQuery, containsPair('page', 1));
      expect(api.lastQuery, containsPair('size', 50));
      expect(api.lastQuery?.containsKey('dateFrom'), isFalse);
      expect(api.lastQuery?.containsKey('dateTo'), isFalse);
      expect(find.text('关系结果 · 点击行查看详情'), findsOneWidget);
      expect(find.text('全部已知关系'), findsOneWidget);
      expect(find.text('全部关系'), findsNothing);
      expect(find.text('墙壁插座成品'), findsOneWidget);

      // 新交互契约：单击只选中，双击才打开产品详情。
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pumpAndSettle();
      expect(find.text('全部历史 · A 螺丝（MAT-001）'), findsOneWidget);
      expect(
        find.byKey(const Key('where-used-current-bom-section')),
        findsOneWidget,
      );
      expect(find.text('退料痕迹数量（待核）'), findsOneWidget);
      expect(find.text('损耗痕迹数量（待核）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('where-used-open-bom')));
      await tester.pumpAndSettle();
      // 整页详情（tab=1 组装信息）：BOM 表拉取并显示空态。
      expect(find.text('该货品暂无组装信息'), findsOneWidget);
      expect(bom.listCalls, [_productId]);

      // 返回反查页（等价于详情页返回键 pop）。
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('墙壁插座成品'), findsOneWidget);

      // 再次双击打开（上一段详情已关闭）。
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('where-used-open-stock-movements')),
      );
      await tester.pumpAndSettle();
      expect(find.text('stock goodsId=$_productId'), findsOneWidget);

      await tester.tap(find.byKey(const Key('stock-test-back')));
      await tester.pumpAndSettle();
      expect(find.text('A 螺丝'), findsOneWidget);
      expect(find.text('墙壁插座成品'), findsOneWidget);
      expect(api.reportCalls, 1);
    },
  );

  testWidgets('preserves the typed API error instead of blaming connection', (
    tester,
  ) async {
    final api = _WhereUsedApi(
      reportError: ApiException('FORBIDDEN', '无权限查看当前反查范围'),
    );
    await _pumpSimplePage(tester, api, size: const Size(1200, 800));

    await _selectMaterial(tester);

    expect(find.text('无权限查看当前反查范围'), findsOneWidget);
    expect(find.textContaining('检查服务连接'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(api.reportCalls, 1);
    expect(tester.takeException(), isNull);
  });

  final responsiveScenarios = <({String name, Size size, double textScale})>[
    (name: '390x844 portrait', size: const Size(390, 844), textScale: 1),
    (
      name: '844x390 landscape with large text',
      size: const Size(844, 390),
      textScale: 1.5,
    ),
  ];
  for (final scenario in responsiveScenarios) {
    testWidgets(
      '${scenario.name} keeps filters, unattributed warning, and table usable',
      (tester) async {
        final api = _WhereUsedApi(
          unattributedDemandCount: 3,
          unattributedDemandQty: 7.5,
        );
        await _pumpSimplePage(
          tester,
          api,
          size: scenario.size,
          textScale: scenario.textScale,
        );

        await _selectMaterial(tester);

        expect(find.textContaining('另有 3 条旧版生产需求'), findsOneWidget);
        expect(find.text('关系结果 · 点击行查看详情'), findsOneWidget);
        expect(find.text('全部已知关系'), findsOneWidget);
        expect(find.text('墙壁插座成品'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
