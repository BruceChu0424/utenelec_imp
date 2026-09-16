// ADR-088 关联订单只读货品清单页。
//
// 这一页的全部价值在于「看得见货品、看不见价格、也点不动任何东西」，
// 所以断言就钉这三件事 + 合计按单位分组不相加。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_analysis_sales_order_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  testWidgets('read-only order lines render with unit-grouped totals', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requests = <RequestOptions>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            _repository(requests),
          ),
        ],
        child: const MaterialApp(
          home: ProductionAnalysisSalesOrderPage(
            analysisId: 'analysis-1',
            orderId: 'order-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 走的是分析下的专用端点，不是销售订单详情。
    expect(requests, hasLength(1));
    expect(
      requests.single.path,
      '/production/material-analyses/analysis-1/sales-orders/order-1',
    );

    expect(find.text('订单货品清单 · SO-088'), findsOneWidget);
    expect(find.text('客户甲'), findsOneWidget);
    expect(find.text('已审核 · 已财务确认'), findsOneWidget);

    // 货品身份三列：名称 / 编号 / 颜色各占一列。
    expect(find.text('货品名称'), findsOneWidget);
    expect(find.text('编号'), findsOneWidget);
    expect(find.text('颜色'), findsOneWidget);
    expect(find.text('产品 A'), findsOneWidget);
    expect(find.text('A-001'), findsOneWidget);
    expect(find.text('B-001'), findsOneWidget);

    // 价格一律不出现：列头与单元格都不许有。
    expect(find.textContaining('单价'), findsNothing);
    expect(find.textContaining('金额'), findsNothing);
    expect(find.textContaining('折扣'), findsNothing);

    // 合计按单位分组，「个」与「箱」绝不相加。
    final totals = tester.widget<UtenTotalsSummaryBar>(
      find.byType(UtenTotalsSummaryBar),
    );
    final byLabel = {
      for (final entry in totals.entries) entry.label: entry.value,
    };
    expect(byLabel['行数'], '2');
    // 分组顺序按 unitId 排序(unit-box 在 unit-piece 前)，不是按行序。
    expect(byLabel['合计订货'], '4 箱 · 10 个');
    expect(byLabel['合计已发'], '4 箱 · 2 个');
    expect(byLabel['合计未发'], '0 箱 · 8 个');
    // 列名与合计标签刻意叫「剩余未排」：调度台那屏的「待排产」是扣过分析承接量的口径。
    expect(byLabel['合计剩余未排'], '0 箱 · 5 个');
    // 列头在横向滚动区之外不构建，所以这里只钉合计标签 + 「待排产」这个词不出现。
    expect(find.text('待排产'), findsNothing);

    // 只读页不提供任何写入动作。
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('保存'), findsNothing);
    expect(find.text('审核'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('order outside the analysis surfaces the server refusal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            _repository(<RequestOptions>[], status: 404),
          ),
        ],
        child: const MaterialApp(
          home: ProductionAnalysisSalesOrderPage(
            analysisId: 'analysis-1',
            orderId: 'foreign-order',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('不在本次物料分析的来源范围内'), findsOneWidget);
    expect(find.text('产品 A'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'back button falls back to the ongoing segment, not a blank analysis',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = GoRouter(
        // 深链直达本页：返回栈为空，走 defaultPath 兜底。
        initialLocation:
            '/production/material-analyses/analysis-1'
            '/sales-orders/order-1',
        routes: [
          GoRoute(
            path: '/production/material-analyses/:id/sales-orders/:orderId',
            builder: (_, state) => ProductionAnalysisSalesOrderPage(
              analysisId: state.pathParameters['id']!,
              orderId: state.pathParameters['orderId']!,
            ),
          ),
          GoRoute(
            path: '/production/progress',
            builder: (_, _) => const Scaffold(body: Text('已回到进行中')),
          ),
          GoRoute(
            path: '/production/material-analysis',
            builder: (_, _) => const Scaffold(body: Text('空白新建分析页')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionPlanRepositoryProvider.overrideWithValue(
              _repository(<RequestOptions>[]),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.text('已回到进行中'), findsOneWidget);
      expect(find.text('空白新建分析页'), findsNothing);
    },
  );
}

ProductionPlanRepository _repository(
  List<RequestOptions> requests, {
  int status = 200,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        if (status != 200) {
          handler.reject(
            DioException(
              requestOptions: request,
              response: Response<dynamic>(
                requestOptions: request,
                statusCode: status,
                data: {'code': 'NOT_FOUND', 'message': '该销售订货单不在本次物料分析的来源范围内'},
              ),
              type: DioExceptionType.badResponse,
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: _order,
          ),
        );
      },
    ),
  );
  return ProductionPlanRepository(ApiClient(dio));
}

const _order = {
  'orderId': 'order-1',
  'billNo': 'SO-088',
  'billDate': '2026-09-01',
  'deliverDate': '2026-09-20',
  'clientName': '客户甲',
  'sellerName': '跟单员乙',
  'status': 1,
  'financeConfirmed': true,
  'closed': false,
  'stopped': false,
  'lines': [
    {
      'orderItemId': 'line-a',
      'lineNo': 1,
      'goodsCode': 'A-001',
      'goodsName': '产品 A',
      'spec': '规格 A',
      'colorName': '白色',
      'unitId': 'unit-piece',
      'unitName': '个',
      'qty': 10,
      'shippedQty': 2,
      'outstandingQty': 8,
      'reservedQty': 1,
      'plannedQty': 2,
      'producedQty': 0,
      'unplannedQty': 5,
      'deliverDate': '2026-09-20',
      'chainStatus': 2,
      'inAnalysis': true,
    },
    {
      'orderItemId': 'line-b',
      'lineNo': 2,
      'goodsCode': 'B-001',
      'goodsName': '产品 B',
      'unitId': 'unit-box',
      'unitName': '箱',
      'qty': 4,
      'shippedQty': 4,
      'outstandingQty': 0,
      'reservedQty': 0,
      'plannedQty': 0,
      'producedQty': 0,
      'unplannedQty': 0,
      'chainStatus': 9,
      'inAnalysis': false,
    },
  ],
};
