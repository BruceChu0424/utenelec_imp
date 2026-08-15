import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_plan_summary_sheet_page.dart';

void main() {
  testWidgets(
    'summary sheet renders company header, three sections, missing-workshop list and aggregated supply rows',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(_workshopApi())],
          child: MaterialApp(
            home: ProductionPlanSummarySheetPage(analysis: _analysis()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 公司头与单据信息（头部事实行是 RichText，按 TextSpan 内容断言）
      expect(find.text('中山市优腾电器有限公司'), findsOneWidget);
      expect(find.text('生产备料计划汇总单'), findsOneWidget);
      final headFacts = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .join('\n');
      expect(headFacts, contains('主仓'));
      expect(headFacts, contains('分析版本'));

      // 三分区
      expect(find.text('一、自制件（按组件安排车间生产）'), findsOneWidget);
      expect(find.text('二、采购件（通知采购部）'), findsOneWidget);
      expect(find.text('三、委外件（通知委外商）'), findsOneWidget);
      expect(find.text('本批已分配'), findsNWidgets(2));

      // 未确认建议路线独立阻断，不得混入采购/委外执行分区
      final pendingRoutes = find.byKey(
        const Key('plan-summary-pending-routes'),
      );
      expect(pendingRoutes, findsOneWidget);
      expect(
        find.descendant(of: pendingRoutes, matching: find.textContaining('铜线')),
        findsOneWidget,
      );

      // 默认车间预填：注塑车间组件有车间，未维护组件进缺车间清单
      expect(find.text('注塑车间'), findsOneWidget);
      final missing = find.byKey(const Key('plan-summary-missing-workshop'));
      expect(missing, findsOneWidget);
      expect(
        find.descendant(of: missing, matching: find.textContaining('面板组件')),
        findsOneWidget,
      );

      // 自制件状态：已有计划号 / 待安排
      expect(find.text('SJ-2026-006'), findsOneWidget);
      expect(find.text('待安排'), findsWidgets);

      // 采购件聚合：两条路径的同货品缺口合并为一行，已通知的显示申请单号
      expect(find.textContaining('ABS 粒料'), findsOneWidget);
      expect(find.text('PR-2026-017'), findsOneWidget);

      // 委外件：未通知显示待通知
      expect(find.textContaining('电镀外壳'), findsOneWidget);
      expect(find.text('待通知'), findsWidgets);

      // 署名区
      expect(find.textContaining('制单：'), findsOneWidget);
      expect(find.textContaining('车间会签：'), findsOneWidget);
    },
  );

  testWidgets('summary sheet hides missing-workshop block when all covered', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_workshopApi(coverAll: true)),
        ],
        child: MaterialApp(
          home: ProductionPlanSummarySheetPage(analysis: _analysis()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('plan-summary-missing-workshop')),
      findsNothing,
    );
    expect(find.text('中山市优腾电器有限公司'), findsOneWidget);
  });
}

ApiClient _workshopApi({bool coverAll = false}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final workshops = <Map<String, dynamic>>[
          <String, dynamic>{
            'goodsId': 'goods-inject',
            'departmentId': 'dept-inject',
            'departmentName': '注塑车间',
          },
          if (coverAll)
            <String, dynamic>{
              'goodsId': 'goods-panel',
              'departmentId': 'dept-assembly',
              'departmentName': '装配车间',
            },
        ];
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: workshops,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

ProductionMaterialAnalysisView _analysis() =>
    const ProductionMaterialAnalysisView(
      analysisId: 'analysis-1',
      version: 3,
      fingerprint: 'fp',
      warehouseId: 'wh-1',
      warehouses: [
        ProductionMaterialAnalysisWarehouse(
          warehouseId: 'wh-1',
          warehouseName: '主仓',
        ),
      ],
      products: [
        ProductionMaterialAnalysisProduct(
          analysisLineId: 'p-1',
          sourceType: 'SALES_ORDER',
          orderNo: 'SO-2026-001',
          goodsId: 'goods-inject',
          goodsCode: 'A1001',
          goodsName: '注塑外壳组件',
          unitName: '件',
          requestedQty: 100,
          readyNowQty: 60,
          latestPlanNo: 'SJ-2026-006',
        ),
        ProductionMaterialAnalysisProduct(
          analysisLineId: 'p-2',
          sourceType: 'MAKE_COMPONENT',
          goodsId: 'goods-panel',
          goodsCode: 'A2002',
          goodsName: '面板组件',
          unitName: '件',
          requestedQty: 40,
          readyNowQty: 20,
        ),
      ],
      materials: [
        // 同货品两条 BOM 路径的采购缺口：汇总单按货品聚合成一行
        ProductionMaterialAnalysisMaterial(
          materialLineId: 'm-1',
          goodsId: 'goods-abs',
          goodsCode: 'M3001',
          goodsName: 'ABS 粒料',
          unitName: 'kg',
          requiredQty: 50,
          availableQty: 10,
          allocatedAvailableQty: 10,
          shortageQty: 40,
          sourceSuggestion: MaterialSupplyRoute.buy,
          routeConfirmed: true,
          sourceConfirmed: MaterialSupplyRoute.buy,
          notifiedTargets: [
            MaterialAnalysisNotificationTarget(
              target: MaterialSupplyRoute.buy,
              documentNo: 'PR-2026-017',
              status: 'NOTIFIED',
            ),
          ],
          actionable: true,
        ),
        ProductionMaterialAnalysisMaterial(
          materialLineId: 'm-2',
          goodsId: 'goods-abs',
          goodsCode: 'M3001',
          goodsName: 'ABS 粒料',
          unitName: 'kg',
          requiredQty: 20,
          availableQty: 10,
          allocatedAvailableQty: 10,
          shortageQty: 10,
          sourceSuggestion: MaterialSupplyRoute.buy,
          routeConfirmed: true,
          sourceConfirmed: MaterialSupplyRoute.buy,
          actionable: true,
        ),
        ProductionMaterialAnalysisMaterial(
          materialLineId: 'm-3',
          goodsId: 'goods-plating',
          goodsCode: 'M4002',
          goodsName: '电镀外壳',
          unitName: '件',
          requiredQty: 30,
          shortageQty: 30,
          sourceSuggestion: MaterialSupplyRoute.subcontract,
          routeConfirmed: true,
          sourceConfirmed: MaterialSupplyRoute.subcontract,
          actionable: true,
        ),
        ProductionMaterialAnalysisMaterial(
          materialLineId: 'm-4',
          goodsId: 'goods-wire',
          goodsCode: 'M5003',
          goodsName: '铜线',
          unitName: 'kg',
          requiredQty: 5,
          shortageQty: 5,
          sourceSuggestion: MaterialSupplyRoute.buy,
          actionable: true,
        ),
      ],
    );
