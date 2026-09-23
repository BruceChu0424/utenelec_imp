// 单据详情页首屏契约(ADR-108 / perf-frontend-05): 首屏只等详情一个请求;
// 字典、货品批量查询、人员姓名在首屏之后并行补齐, 补齐后重绘一次;
// 服务端随单已给的姓名直接用, 不再按 id 逐个查员工详情。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_plan_detail_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

/// 记录请求路径; 字典/货品查询/员工详情挂起, 直到测试手动放行。
class _GatedApi {
  _GatedApi(this.detailPath, this.detail);

  final String detailPath;
  final Map<String, dynamic> detail;
  final List<String> paths = [];
  final Completer<void> gate = Completer<void>();

  bool _gated(String path) =>
      path.endsWith('/dict') ||
      path == '/master/goods/lookup' ||
      path.startsWith('/org/employees/');

  ApiClient client() {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final path = request.path;
          paths.add(path);
          if (_gated(path)) await gate.future;
          final Object data;
          if (path == detailPath) {
            data = detail;
          } else if (path == '/master/goods/lookup') {
            data = [
              {
                'id': 'g-1',
                'name': '货品甲',
                'code': 'G-001',
                'stockPlace': 'A-01',
              },
            ];
          } else if (path.startsWith('/org/employees/')) {
            data = {'fullName': '张三'};
          } else if (path.endsWith('/dict')) {
            data = <Map<String, dynamic>>[];
          } else {
            data = <String, dynamic>{};
          }
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
}

/// 挂起的请求不会结束, 不能 pumpAndSettle; 推进几帧让详情请求与首屏走完。
Future<void> _pumpWhileGated(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('销售订单详情: 首屏只等详情, 名称补齐不挡首屏且只补一次', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gated = _GatedApi('/sales/orders/order-1', {
      'id': 'order-1',
      'billNo': 'SO-FIRST-PAINT',
      'status': 1,
      'sellerId': 'emp-1',
      'items': [
        {
          'id': 'line-1',
          'goodsId': 'g-1',
          'goodsNameSnapshot': '货品甲',
          'goodsCodeSnapshot': 'G-001',
          'qty': 2,
        },
      ],
    });
    final api = gated.client();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: SalesDocDetailPage(docType: SalesDocType.order, id: 'order-1'),
        ),
      ),
    );
    await _pumpWhileGated(tester);

    // 字典/货品/员工全部挂起时, 详情已经渲染出来。
    expect(gated.gate.isCompleted, isFalse);
    expect(find.textContaining('SO-FIRST-PAINT'), findsWidgets);
    expect(find.text('张三'), findsNothing);

    gated.gate.complete();
    await tester.pumpAndSettle();

    // 放行后补齐的姓名出现(页面重绘了一次)。
    expect(find.text('张三'), findsWidgets);
    // 货品一次批量查询(不再「先查名称再查详情」两次); 员工只查表头要显示的那一个。
    expect(gated.paths.where((p) => p == '/master/goods/lookup'), hasLength(1));
    expect(gated.paths.where((p) => p.startsWith('/org/employees/')), [
      '/org/employees/emp-1',
    ]);
    expect(
      gated.paths.where((p) => p == '/sales/orders/order-1'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('生产计划详情: 服务端随单给了负责人/跟单员姓名就不再查员工详情', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gated = _GatedApi('/production/plans/plan-1', {
      'id': 'plan-1',
      'billNo': 'SJ-FIRST-PAINT',
      'billDate': '2026-09-23',
      'status': -1,
      'workerId': 'emp-worker',
      'workerName': '李四',
      'sellerId': 'emp-seller',
      'sellerName': '王五',
      'allowedActions': const ['VIEW'],
      'items': <Map<String, dynamic>>[],
    });
    final api = gated.client();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionPlanRepositoryProvider.overrideWithValue(
            ProductionPlanRepository(api),
          ),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
        ],
        child: const MaterialApp(home: ProductionPlanDetailPage(id: 'plan-1')),
      ),
    );
    await _pumpWhileGated(tester);

    // 字典还挂着, 首屏已出, 且姓名直接用服务端给的。
    expect(gated.gate.isCompleted, isFalse);
    expect(find.text('李四'), findsWidgets);
    expect(find.text('王五'), findsWidgets);

    gated.gate.complete();
    await tester.pumpAndSettle();

    expect(gated.paths.where((p) => p.startsWith('/org/employees/')), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
