// 我的车间任务「等待物料」段默认排序（2026-09-26 用户口径「越接近可开工越靠上」）
// 与状态列整格底色（同口径 B7）的回归。
//
// 2026-09-15 服务端曾按旧布尔（issued/drawRequested）排过档；2026-09-20 ADR-095
// 改为逐种物料事实后服务端档位与新词表脱钩，本测试锁定客户端按词表 tone 的排序：
// 物料齐 > 部分齐 > 缺料/更不齐，同档内按工单号稳定次序。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/pages/production_workshop_tasks_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../../support/filter_segment_tap.dart';

void main() {
  testWidgets('preparing rows sort closest-to-startable first', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _preparingApi();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionExecutionView,
          Perm.productionExecutionStart,
        }),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: RouteName.productionWorkshopTasks,
      routes: [
        GoRoute(
          path: RouteName.productionWorkshopTasks,
          builder: (_, _) => const ProductionWorkshopTasksPage(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await selectFilterSegment(tester, '等待物料');
    await tester.pumpAndSettle();

    double topOf(String text) => tester.getTopLeft(find.text(text)).dy;
    // 服务端返回顺序：缺料 GD-0 / 缺料 GD-9 / 部分齐 GD-5 / 物料齐 GD-7。
    // 客户端排序后：物料齐 → 部分齐 → 缺料（同档内按工单号 GD-0 < GD-9）。
    expect(topOf('产品 齐'), lessThan(topOf('产品 部分')));
    expect(topOf('产品 部分'), lessThan(topOf('产品 缺零')));
    expect(topOf('产品 缺零'), lessThan(topOf('产品 缺玖')));
    // 阶段文案与档位一一对应（排序的依据就是这些 tone）。
    expect(find.textContaining('物料已领齐 · 可开工'), findsOneWidget);
    expect(find.textContaining('部分物料已投 · 可开工'), findsOneWidget);
    expect(find.textContaining('等待物料到齐 · 已备 2/3 种'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}

/// 四条等待物料任务的假 API（服务端按 plan_no 返回「越不齐越靠前」的乱序）。
ApiClient _preparingApi() {
  Map<String, dynamic> task({
    required String segmentId,
    required String segmentCode,
    required String productName,
    required String segmentStatus,
    required int kindCount,
    int issuedKindCount = 0,
    int shortKindCount = 0,
    bool canStart = false,
  }) => {
    'segmentId': segmentId,
    'planId': 'plan-$segmentId',
    'planNo': 'SJ-$segmentCode',
    'segmentCode': segmentCode,
    'workshopDepartmentId': 'workshop-1',
    'workshopName': '装配一车间',
    'productCode': 'P-$segmentCode',
    'productName': productName,
    'productColorName': '本色',
    'productUnitName': '件',
    'plannedQty': 100,
    'reportedQty': 0,
    'remainingReportQty': 100,
    'segmentStatus': segmentStatus,
    'materialStatus': 'KIT_SHORT',
    'preparationStatus': 'PREPARING',
    'materialReady': false,
    'warehouseReady': false,
    'issued': false,
    'canStart': canStart,
    'canReport': false,
    'lockVersion': 1,
    'startRoute': 'FULL_KIT',
    'materialKindCount': kindCount,
    'materialIssuedKindCount': issuedKindCount,
    'materialShortKindCount': shortKindCount,
  };
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final data = switch (request.path) {
          '/production/workshop-tasks' => {
            'items': [
              // 缺料（等待物料到齐 · 已备 2/3 种）——工单号最大，排序后应垫底。
              task(
                segmentId: 'seg-short-9',
                segmentCode: 'GD-9',
                productName: '产品 缺玖',
                segmentStatus: 'READY',
                kindCount: 3,
                shortKindCount: 1,
              ),
              // 物料齐（物料已领齐 · 可开工）——服务端返回在最底，排序后应置顶。
              task(
                segmentId: 'seg-ready',
                segmentCode: 'GD-7',
                productName: '产品 齐',
                segmentStatus: 'READY',
                kindCount: 1,
                issuedKindCount: 1,
                canStart: true,
              ),
              // 缺料（同档，工单号更小）。
              task(
                segmentId: 'seg-short-0',
                segmentCode: 'GD-0',
                productName: '产品 缺零',
                segmentStatus: 'READY',
                kindCount: 3,
                shortKindCount: 1,
              ),
              // 部分齐（部分物料已投 · 可开工）。
              task(
                segmentId: 'seg-partial',
                segmentCode: 'GD-5',
                productName: '产品 部分',
                segmentStatus: 'READY',
                kindCount: 2,
                issuedKindCount: 1,
                canStart: true,
              ),
            ],
            'page': 1,
            'size': 50,
            'total': 4,
            'totalPages': 1,
          },
          '/production/workshop-tasks/count' => {'count': 4},
          '/production/daily-reports' => {
            'items': <Map<String, dynamic>>[],
            'page': 1,
            'size': 100,
            'total': 0,
            'totalPages': 1,
          },
          _ => <String, dynamic>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
