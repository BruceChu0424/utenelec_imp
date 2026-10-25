import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_history_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import '../../../support/page_resume_test_bridge.dart';

void main() {
  for (final scale in [1.0, 1.6]) {
    testWidgets('375px下500产品卡标题有限高且来源数量可见 $scale', (tester) async {
      await tester.binding.setSurfaceSize(const Size(375, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.physicalSize = const Size(375, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final labels = List.generate(
        500,
        (index) => 'UAT-LOAD负载产品${index + 1}（P-${index + 1} · 白色）',
      );
      final payload = _analysisPage();
      final row = (payload['items']! as List).single as Map<String, dynamic>;
      row['productLabels'] = labels;
      row['sourceCount'] = 500;
      row['sourceTypes'] = ['SALES_ORDER_ITEM'];
      row['sourceRefs'] = ['SO-375-001'];
      final router = GoRouter(
        initialLocation: RouteName.productionMaterialAnalysisHistory,
        routes: [
          GoRoute(
            path: RouteName.productionMaterialAnalysisHistory,
            builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(),
          ),
          GoRoute(
            path: RouteName.productionMaterialAnalysis,
            builder: (_, state) {
              final seed = state.extra! as ProductionMaterialAnalysisSeed;
              return Scaffold(
                body: Text(
                  'resume-${seed.analysisId}-${seed.analysisVersion}-${seed.warehouseId}',
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            masterNameServiceProvider.overrideWithValue(_PlanningMainNames()),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(_api([], payload: payload)),
            ),
          ],
          child: PageResumeTestBridge(
            router: router,
            child: MaterialApp.router(
              routerConfig: router,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final title = find.text(labels.join('、'));
      final card = find.byKey(const Key('analysis-history-row-analysis-1'));
      debugPrint(
        '375px/$scale analysis card height=${tester.getSize(card).height} title=${tester.getSize(title).height}',
      );
      expect(
        tester.getSize(card).height,
        lessThan(600),
        reason: '单卡应呈现摘要，不能随500个产品线性增高',
      );
      expect(tester.getSize(title).height, lessThanOrEqualTo(80));
      expect(
        find.ancestor(of: title, matching: find.byType(Tooltip)),
        findsNothing,
        reason: '不把500产品整串挂进窄屏Tooltip',
      );
      expect(
        tester.widget<Text>(title).data,
        labels.join('、'),
        reason: '只限制视觉行数，完整数据仍保留',
      );
      expect(find.textContaining('SO-375-001').hitTestable(), findsOneWidget);
      expect(
        find.text('需求 100 · 已提交 10 · 已批准 5 · 待处理 85').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(
        find.text('resume-analysis-1-8-warehouse-1'),
        findsOneWidget,
        reason: '卡片仍打开同一完整分析，不改身份/版本/主仓',
      );
    });
  }
  for (final width in [1200.0, 834.0, 375.0]) {
    testWidgets('分析记录刷新在顶栏且保留查询 $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <RequestOptions>[];
      final router = GoRouter(
        initialLocation: RouteName.productionMaterialAnalysisHistory,
        routes: [
          GoRoute(
            path: RouteName.productionMaterialAnalysisHistory,
            builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            masterNameServiceProvider.overrideWithValue(_PlanningMainNames()),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(_api(requests)),
            ),
          ],
          child: PageResumeTestBridge(
            router: router,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(
              find.byWidgetPredicate(
                (widget) => widget is UtenDropdownField && widget.label == '状态',
              ),
            )
            .width,
        lessThanOrEqualTo(190),
        reason: '筛选字段按内容宽度自然换行，不强占整行宽度',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('analysis-history-search')),
          matching: find.byType(TextField),
        ),
        'KEEP-SOURCE',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      tester
          .widget<UtenDropdownField>(
            find.byWidgetPredicate(
              (widget) => widget is UtenDropdownField && widget.label == '状态',
            ),
          )
          .onChanged('ACTIVE');
      await tester.pumpAndSettle();
      tester
          .widget<UtenDropdownField>(
            find.byWidgetPredicate(
              (widget) => widget is UtenDropdownField && widget.label == '需求来源',
            ),
          )
          .onChanged('REWORK');
      await tester.pumpAndSettle();
      final refresh = find.byKey(const Key('analysis-history-refresh'));
      final more = find.byKey(const Key('uten-app-bar-more-actions'));
      final action = refresh.evaluate().isEmpty ? more : refresh;
      expect(
        find.ancestor(of: action, matching: find.byType(UtenAppBar)),
        findsOneWidget,
      );
      if (refresh.evaluate().isEmpty) {
        await tester.tap(more);
        await tester.pumpAndSettle();
      }
      final before = requests.length;
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(requests.length, before + 1);
      expect(requests.last.queryParameters['keyword'], 'KEEP-SOURCE');
      expect(requests.last.queryParameters['status'], 'ACTIVE');
      expect(requests.last.queryParameters['sourceType'], 'REWORK');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'desktop history exposes server facts and resumes by analysis id',
    (tester) async {
      final requests = <RequestOptions>[];
      final api = _api(requests);
      final router = GoRouter(
        initialLocation: RouteName.productionMaterialAnalysisHistory,
        routes: [
          GoRoute(
            path: RouteName.productionMaterialAnalysisHistory,
            builder: (_, _) => const ProductionMaterialAnalysisHistoryPage(),
          ),
          GoRoute(
            path: RouteName.productionMaterialAnalysis,
            builder: (_, state) {
              final seed = state.extra! as ProductionMaterialAnalysisSeed;
              return Scaffold(body: Text('resume-${seed.analysisId}'));
            },
          ),
          GoRoute(
            path: RouteName.productionPlanList,
            builder: (_, _) => const Scaffold(body: Text('plan-history')),
          ),
        ],
      );
      addTearDown(router.dispose);

      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            masterNameServiceProvider.overrideWithValue(_PlanningMainNames()),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
          ],
          child: PageResumeTestBridge(
            router: router,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('analysis-history-table')), findsOneWidget);
      expect(find.text('部分已下达，剩余待料'), findsWidgets);
      expect(find.textContaining('返工、自制子需求'), findsOneWidget);
      expect(find.textContaining('RW-20260808-001'), findsOneWidget);
      expect(find.text('生产调度员'), findsOneWidget);
      expect(find.text('12 / 30'), findsOneWidget);
      expect(find.text('继续处理 →'), findsOneWidget);
      expect(
        requests.map((request) => request.path),
        contains('/production/material-analyses'),
      );

      // 新交互契约：单击只选中，双击才打开（resume）。
      await tester.tap(find.textContaining('RW-20260808-001'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.textContaining('RW-20260808-001'));
      await tester.pumpAndSettle();
      expect(find.text('resume-analysis-1'), findsOneWidget);
      final readsBeforeReturn = requests.length;
      router.pop();
      await tester.pumpAndSettle();
      expect(requests.length, readsBeforeReturn + 1);
      expect(find.byKey(const Key('analysis-history-table')), findsOneWidget);
    },
  );
}

ApiClient _api(List<RequestOptions> requests, {Map<String, dynamic>? payload}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: payload ?? _analysisPage(),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _analysisPage() => {
  'items': [
    {
      'analysisId': 'analysis-1',
      'status': 'PARTIALLY_PLANNED',
      'version': 8,
      'fingerprint': 'a' * 64,
      'warehouseId': 'warehouse-1',
      'warehouseCode': 'WH-01',
      'warehouseName': '主仓',
      'analyzedAt': '2026-08-08T02:00:00Z',
      'updatedAt': '2026-08-08T03:00:00Z',
      'makerId': 'employee-1',
      'makerName': '生产调度员',
      'sourceCount': 1,
      'sourceTypes': ['REWORK', 'MAKE_COMPONENT'],
      'sourceRefs': ['RW-20260808-001'],
      'productLabels': ['P-001 返工产品'],
      'requestedQty': 100,
      'submittedQty': 10,
      'approvedQty': 5,
      'remainingQty': 85,
      'readyNowQty': 12,
      'readyByDateQty': 30,
    },
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
};

class _PlanningMainNames extends MasterNameService {
  _PlanningMainNames() : super(ApiClient(Dio()));
  @override
  Future<void> ensureCommonLoaded() async {}
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'planning-main', name: '主仓'),
    WarehouseDictEntry(
      id: 'warehouse-1',
      name: '实际子仓',
      parentId: 'planning-main',
      selectableForNew: true,
    ),
  ];
}
