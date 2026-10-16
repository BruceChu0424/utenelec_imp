import 'dart:async';
import 'dart:io' show Directory;

import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/production/pages/where_used_report_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_production_trace_view.dart';
import '../../support/filter_segment_tap.dart';
import '../../support/audit_screenshot_support.dart';

const _materialId = '11111111-1111-4111-8111-111111111111';
const _productId = '22222222-2222-4222-8222-222222222222';
const _captureUi = bool.fromEnvironment('UTEN_CAPTURE_UI');
const _captureBoundary = Key('where-used-capture');
const _actualPermissions = {
  Perm.productionWhereUsedView,
  Perm.stockView,
  Perm.stockDocView,
  Perm.productionPlanView,
  Perm.productionDailyReportView,
  Perm.supplierView,
};
final _livePermissions = StateProvider<Set<String>>(
  (ref) => {Perm.productionWhereUsedView},
);
final _liveIdentity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'viewer'),
);
final _liveApi = StateProvider<ApiClient?>((ref) => null);

class _WhereUsedApi extends ApiClient {
  _WhereUsedApi({
    this.reportError,
    this.unattributedDemandCount = 0,
    this.unattributedDemandQty = 0,
    this.traceError,
    this.richActual = false,
  }) : super(Dio());

  Object? reportError;
  final Object? traceError;
  final bool richActual;
  Completer<void>? reportGate;
  final int unattributedDemandCount;
  final num unattributedDemandQty;

  int materialCalls = 0;
  int reportCalls = 0;
  int traceCalls = 0;
  final traceQueries = <Map<String, dynamic>>[];
  final subjectQueries = <Map<String, dynamic>>[];
  Map<String, dynamic>? lastMaterialQuery;
  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/reports/where-used/subjects') {
      final q = Map<String, dynamic>.from(query ?? {});
      subjectQueries.add(q);
      final batch = q['kind'] == 'batch';
      return {
        'items': [
          if (batch)
            {
              'type': 'PRODUCTION_OUTPUT_LOT',
              'id': 'production-lot-1',
              'code': 'LOT-001',
              'label': '实际生产批次',
            }
          else ...[
            {
              'type': 'PURCHASE_ORDER',
              'id': 'purchase-order-1',
              'code': 'DUP-001',
              'label': '采购订货',
            },
            {
              'type': 'SUBCONTRACT_ORDER',
              'id': 'subcontract-order-1',
              'code': 'DUP-001',
              'label': '委外订货',
            },
          ],
        ],
        'page': 1,
        'size': 30,
        'total': batch ? 1 : 2,
        'totalPages': 1,
      };
    }
    if (path == '/production/reports/where-used/trace') {
      ++traceCalls;
      final q = Map<String, dynamic>.from(query ?? {});
      traceQueries.add(q);
      if (traceError != null) throw traceError!;
      return {
        'subject': {
          'type': q['subjectType'],
          'id': q['subjectId'],
          'code': 'SELECTED',
          'label': '已选对象',
        },
        'items': richActual
            ? _richActualRows()
            : [
                {
                  'id': 'actual-row-1',
                  'kind': 'ORDER',
                  'planId': 'plan-1',
                  'planNo': 'PLAN-001',
                  'product': {
                    'goodsId': _productId,
                    'goodsName': '实际生产产品',
                    'goodsCode': 'CP-001',
                    'unitName': '个',
                  },
                  'material': {
                    'goodsId': _materialId,
                    'goodsName': '实际领用物料',
                    'unitName': '千克',
                  },
                  'issuedQty': '1.2500',
                  'returnedQty': '0',
                  'consumedQty': null,
                  'drawDocuments': <Object>[],
                  'reports': <Object>[],
                  'receiptSources': <Object>[],
                },
              ],
        'sources': <Object>[],
        'coverageNotes': <Object>[],
        'page': 1,
        'size': 50,
        'total': richActual ? 3 : 1,
        'totalPages': 1,
      };
    }
    if (path == '/production/reports/where-used/materials') {
      materialCalls += 1;
      lastMaterialQuery = Map<String, dynamic>.of(query ?? const {});
      return <String, dynamic>{
        'items': [
          {
            'id': _materialId,
            'code': richActual ? 'RAW-ABS01' : 'MAT-001',
            'name': richActual ? 'ABS 注塑原料' : 'A 螺丝',
            'model': richActual ? 'ABS-100' : 'M3',
            'spec': richActual ? '通用级注塑颗粒' : '镀锌',
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
    if (reportGate != null) await reportGate!.future;
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

List<Map<String, dynamic>> _richActualRows() => [
  for (final item in [
    (
      no: 1,
      name: '86型开关外壳',
      color: '白色',
      issued: '12.5',
      returned: '0.5',
      consumed: '12',
      output: '2000',
    ),
    (
      no: 2,
      name: 'USB 插座面板',
      color: '灰色',
      issued: '8.75',
      returned: '0.25',
      consumed: '8.5',
      output: '1500',
    ),
    (
      no: 3,
      name: '双联防水底座',
      color: '黑色',
      issued: '16',
      returned: '0',
      consumed: '16',
      output: '1200',
    ),
  ])
    {
      'id': 'actual-rich-${item.no}',
      'kind': 'ORDER',
      'quantityBasis': '已过账领退料与核销记录',
      'planId': 'plan-${item.no}',
      'planNo': 'SC20261015000${item.no}',
      'segmentCode': 'GD-20261015-${item.no}',
      'workshopName': '注塑车间',
      'product': {
        'goodsId': 'product-${item.no}',
        'goodsName': item.name,
        'goodsCode': 'CP-00${item.no}',
        'colorName': item.color,
        'unitName': '个',
      },
      'material': {
        'goodsId': _materialId,
        'goodsName': 'ABS 注塑原料',
        'goodsCode': 'RAW-ABS01',
        'colorName': '本色',
        'unitName': '千克',
      },
      'issuedQty': item.issued,
      'returnedQty': item.returned,
      'consumedQty': item.consumed,
      'lossQty': '0',
      'drawDocuments': [
        {
          'id': 'draw-${item.no}',
          'billNo': 'LL20261015000${item.no}',
          'billDate': '2026-10-15',
          'docType': 'DRAW',
        },
      ],
      'reports': [
        {
          'id': 'report-${item.no}',
          'billNo': 'BG20261015000${item.no}',
          'billDate': '2026-10-15',
          'productQty': item.output,
          'unitName': '个',
          'workers': [
            {'id': 'worker-1', 'name': '张师傅'},
          ],
          'batches': [
            {
              'id': 'lot-${item.no}',
              'code': 'LOT-20261015-00${item.no}',
              'lineNo': item.no,
              'productQty': item.output,
              'unitName': '个',
            },
          ],
        },
      ],
      'receiptSources': [
        {
          'id': 'receipt-1',
          'billNo': 'CJ202610120001',
          'billDate': '2026-10-12',
          'supplierName': '华南材料',
          'qty': item.issued,
          'sourceBasis': '入库来源分配，非逐批实耗',
          'sourceDocType': 'PURCHASE_RECEIPT',
          'sourceDocCode': 'CJ',
        },
      ],
    },
];

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
  Set<String>? permissions,
  ThemeData? theme,
}) async {
  _configureView(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWith((ref) => ref.watch(_liveApi) ?? api),
        if (permissions != null)
          _livePermissions.overrideWith((ref) => permissions),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_livePermissions),
        ),
        authenticatedScopeProvider.overrideWith(
          (ref) => ref.watch(_liveIdentity),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: RepaintBoundary(
        key: _captureBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
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
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectMaterial(
  WidgetTester tester, {
  bool settleReport = true,
  String keyword = 'MAT-001',
}) async {
  await tester.tap(find.text('搜索并选择物料'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('where-used-material-search')),
    keyword,
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  final material = find.byKey(
    const ValueKey('where-used-material-$_materialId'),
  );
  await tester.ensureVisible(material);
  await tester.tap(material);
  if (settleReport) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  for (final viewport in [
    (width: 1440.0, height: 1000.0, scale: 1.0),
    (width: 375.0, height: 812.0, scale: 2.0),
  ]) {
    testWidgets('capture material trace actual ${viewport.width.toInt()}', (
      tester,
    ) async {
      await loadAuditScreenshotFonts(tester);
      final api = _WhereUsedApi(richActual: true);
      await _pumpSimplePage(
        tester,
        api,
        size: Size(viewport.width, viewport.height),
        textScale: viewport.scale,
        permissions: _actualPermissions,
        theme: auditScreenshotTheme(buildLightTheme()),
      );
      await _selectMaterial(tester, keyword: 'RAW-ABS01');
      await selectFilterSegment(tester, '实际追溯');
      await tester.pumpAndSettle();
      expect(api.traceCalls, 1);
      expect(find.byType(GoodsProductionTraceView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(_captureBoundary),
        matchesGoldenFile(
          Directory.current.uri.resolve(
            '.local-artifacts/material-trace-actual-${viewport.width.toInt()}.png',
          ),
        ),
      );
      if (viewport.width > 1000) {
        await tester.tap(find.text('86型开关外壳'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('86型开关外壳'));
        await tester.pumpAndSettle();
        expect(find.text('用料追溯'), findsOneWidget);
        final detailList = find.byType(ListView).last;
        final batch = find.descendant(
          of: detailList,
          matching: find.text('生产批次：LOT-20261015-001'),
        );
        await tester.scrollUntilVisible(
          batch,
          160,
          scrollable: find
              .descendant(of: detailList, matching: find.byType(Scrollable))
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('继续追溯此批次'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(_captureBoundary),
          matchesGoldenFile(
            Directory.current.uri.resolve(
              '.local-artifacts/material-trace-production-batch-1440.png',
            ),
          ),
        );
      }
    }, skip: !_captureUi);
  }

  testWidgets(
    'theory refresh permission denial clears the last successful evidence',
    (tester) async {
      final api = _WhereUsedApi();
      await _pumpSimplePage(tester, api, size: const Size(1400, 900));
      await _selectMaterial(tester);
      expect(find.text('墙壁插座成品'), findsOneWidget);
      api.reportError = ApiException('FORBIDDEN', '当前关系范围已撤权', httpStatus: 403);
      await tester.tap(find.byTooltip('刷新当前结果'));
      await tester.pumpAndSettle();
      expect(find.text('墙壁插座成品'), findsNothing);
      expect(find.text('当前关系范围已撤权'), findsOneWidget);
      expect(find.textContaining('已保留上次成功结果'), findsNothing);
      expect(api.traceCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'relationship source filters retain all choices and cancel does not query',
    (tester) async {
      final api = _WhereUsedApi();
      await _pumpSimplePage(tester, api, size: const Size(1400, 900));
      await _selectMaterial(tester);
      final before = api.reportCalls;
      await tester.tap(find.byKey(const Key('where-used-filters')));
      await tester.pumpAndSettle();
      tester
          .widget<UtenDropdownField>(
            find.byKey(const Key('where-used-source-filter')),
          )
          .onChanged('current');
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(api.reportCalls, before);
      expect(api.lastQuery?['source'], 'all');
      for (final source in [
        'current',
        'history',
        'production',
        'subcontract',
        'all',
      ]) {
        await tester.tap(find.byKey(const Key('where-used-filters')));
        await tester.pumpAndSettle();
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('where-used-source-filter')),
            )
            .onChanged(source);
        await tester.tap(find.byKey(const Key('where-used-filter-apply')));
        await tester.pumpAndSettle();
        expect(api.lastQuery?['source'], source);
        expect(api.lastQuery?.containsKey('dateFrom'), isFalse);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'where-used-only access keeps theory default and explanations on demand',
    (tester) async {
      final api = _WhereUsedApi();
      await _pumpSimplePage(tester, api, size: const Size(1400, 900));
      await _selectMaterial(tester);
      expect(api.reportCalls, 1);
      expect(api.traceCalls, 0);
      expect(find.text('墙壁插座成品'), findsOneWidget);
      expect(find.textContaining('当前可用的已知关系 ='), findsNothing);
      await tester.tap(find.byKey(const Key('where-used-basis')));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前可用的已知关系 ='), findsOneWidget);
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      expect(find.text('墙壁插座成品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual permission rejection is explicit and does not remove theory access',
    (tester) async {
      final api = _WhereUsedApi(
        traceError: ApiException('FORBIDDEN', '无权查看实际生产凭证', httpStatus: 403),
      );
      await _pumpSimplePage(tester, api, size: const Size(1400, 900));
      await _selectMaterial(tester);
      await selectFilterSegment(tester, '实际追溯');
      await tester.pumpAndSettle();
      expect(find.text('无权查看实际生产凭证'), findsOneWidget);
      expect(api.traceCalls, 1);
      await selectFilterSegment(tester, 'BOM 与历史关系');
      await tester.pumpAndSettle();
      expect(find.text('墙壁插座成品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (
      kind: 'document',
      type: 'PURCHASE_ORDER',
      id: 'purchase-order-1',
      keyword: 'DUP-001',
    ),
    (
      kind: 'document',
      type: 'SUBCONTRACT_ORDER',
      id: 'subcontract-order-1',
      keyword: 'DUP-001',
    ),
    (
      kind: 'batch',
      type: 'PRODUCTION_OUTPUT_LOT',
      id: 'production-lot-1',
      keyword: 'LOT-001',
    ),
  ]) {
    testWidgets(
      'explicit ${scenario.type} identity drives actual trace and direction',
      (tester) async {
        final api = _WhereUsedApi();
        await _pumpSimplePage(
          tester,
          api,
          size: const Size(1400, 900),
          permissions: _actualPermissions,
        );
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('where-used-entry-kind')),
            )
            .onChanged(scenario.kind);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('where-used-query-subject')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('material-trace-subject-search')),
          scenario.keyword,
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(api.traceCalls, 0, reason: '匹配单号不是自动绑定，必须选择类型与真实ID');
        await tester.tap(
          find.byKey(
            ValueKey(('material-trace-subject', scenario.type, scenario.id)),
          ),
        );
        await tester.pumpAndSettle();
        expect(api.traceQueries.last['subjectType'], scenario.type);
        expect(api.traceQueries.last['subjectId'], scenario.id);
        expect(api.reportCalls, 0);
        expect(find.byType(GoodsProductionTraceView), findsOneWidget);
        await tester.tap(find.text('BOM 与历史关系'));
        await tester.pumpAndSettle();
        expect(api.reportCalls, 0, reason: '单据与生产批次不能当作货品BOM身份');
        if (scenario.type == 'PRODUCTION_OUTPUT_LOT') {
          await selectFilterSegment(tester, '用了哪些物料');
          await tester.pumpAndSettle();
          expect(api.traceQueries.last['direction'], 'materials');
          expect(api.traceQueries.last['subjectId'], scenario.id);
        } else {
          expect(
            find.text('用了哪些物料'),
            findsNothing,
            reason: '订货单不提供没有业务差异的方向切换',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final change in ['account', 'api', 'permission']) {
    testWidgets(
      '$change invalidates a pending theory response and selected subject',
      (tester) async {
        final api = _WhereUsedApi()..reportGate = Completer<void>();
        await _pumpSimplePage(tester, api, size: const Size(1400, 900));
        await _selectMaterial(tester, settleReport: false);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(WhereUsedReportPage)),
        );
        if (change == 'account') {
          container.read(_liveIdentity.notifier).state =
              const AuthenticatedScope(userId: 'other-viewer');
        } else if (change == 'api') {
          container.read(_liveApi.notifier).state = _WhereUsedApi();
        } else {
          container.read(_livePermissions.notifier).state = {};
        }
        await tester.pumpAndSettle();
        api.reportGate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('搜索并选择物料'), findsOneWidget);
        expect(find.text('墙壁插座成品'), findsNothing);
        expect(find.byType(GoodsProductionTraceView), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'equal permission refresh preserves selected subject and open details',
    (tester) async {
      final api = _WhereUsedApi();
      await _pumpSimplePage(tester, api, size: const Size(1400, 900));
      await _selectMaterial(tester);
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('where-used-product-detail-dialog')),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WhereUsedReportPage)),
      );
      container.read(_livePermissions.notifier).state = {
        Perm.productionWhereUsedView,
      };
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('where-used-product-detail-dialog')),
        findsOneWidget,
      );
      expect(api.reportCalls, 1);
      container.read(_liveIdentity.notifier).state = const AuthenticatedScope(
        userId: 'other',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('where-used-product-detail-dialog')),
        findsNothing,
      );
      expect(find.text('搜索并选择物料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-day history picker range remains queryable across UTC and device dates',
    (tester) async {
      final api = _WhereUsedApi();
      await _pumpSimplePage(tester, api, size: const Size(1400, 900));
      await _selectMaterial(tester);
      await tester.tap(find.byKey(const Key('where-used-filters')));
      await tester.pumpAndSettle();
      await selectFilterSegment(tester, '自定义');
      await tester.pumpAndSettle();
      // Invoke the real control callback: this regression targets date-carrier
      // boundaries, independently of the existing collapsible-header layout.
      tester
          .widget<OutlinedButton>(find.byKey(const Key('where-used-date-from')))
          .onPressed!();
      await tester.pumpAndSettle();
      final today = ChinaDateTime.today();
      tester
          .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
          .onDateChanged(DateTime(today.year, today.month, today.day));
      await tester.pumpAndSettle();
      final ok = MaterialLocalizations.of(
        tester.element(find.byType(CalendarDatePicker)),
      ).okButtonLabel;
      await tester.tap(find.text(ok));
      await tester.pumpAndSettle();
      final before = api.reportCalls;
      tester
          .widget<FilledButton>(
            find.byKey(const Key('where-used-filter-apply')),
          )
          .onPressed!();
      await tester.pumpAndSettle();
      expect(api.reportCalls, before + 1);
      expect(api.lastQuery?['dateFrom'], ChinaDateTime.formatDate(today));
      expect(api.lastQuery?['dateTo'], ChinaDateTime.formatDate(today));
    },
  );
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
              initialTab: s.uri.queryParameters['tab'],
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
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'viewer'),
            ),
            isSuperAdminProvider.overrideWithValue(false),
            goodsRepositoryProvider.overrideWithValue(goods),
            goodsBomRepositoryProvider.overrideWithValue(bom),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.goodsView,
              Perm.stockView,
            }),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
          ),
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
      expect(find.text('BOM 与历史关系'), findsOneWidget);
      expect(find.text('全部已知关系'), findsOneWidget);
      expect(find.text('全部关系'), findsNothing);
      expect(find.text('墙壁插座成品'), findsOneWidget);

      // 新交互契约：单击只选中，双击才打开产品详情。
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('墙壁插座成品'));
      await tester.pumpAndSettle();
      expect(find.text('全部历史 · A 螺丝(MAT-001)'), findsOneWidget);
      expect(
        find.byKey(const Key('where-used-current-bom-section')),
        findsOneWidget,
      );
      expect(find.text('退料痕迹数量(待核)'), findsOneWidget);
      expect(find.text('损耗痕迹数量(待核)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('where-used-open-bom')));
      await tester.pumpAndSettle();
      // 整页详情 (tab=bom 组装信息)：BOM 表拉取并显示空态。
      expect(find.text('暂无组装信息，点右下「添加组件」录入'), findsOneWidget);
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
      expect(
        find.descendant(
          of: find.byKey(const Key('where-used-query-subject')),
          matching: find.text('A 螺丝 · MAT-001'),
        ),
        findsOneWidget,
      );
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
    (
      name: '375x812 with double text',
      size: const Size(375, 812),
      textScale: 2,
    ),
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
        expect(find.text('BOM 与历史关系'), findsOneWidget);
        expect(find.text('全部已知关系'), findsOneWidget);
        expect(find.text('墙壁插座成品'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
