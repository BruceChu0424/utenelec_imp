// 到货登记 → 审核页直达的导航链路 widget 测试。
//
// 覆盖 2026-08-20 改的流转：预计到货任务中心点「登记实际到货」→ 登记页保存成功后
// pop(新建收货单 id) → 任务中心重载列表并自动 push 到该收货单详情（审核页）。
// 用委外（SUBCONTRACT）类型：无需采购员，收货人默认当前登录人，表单最小可提交。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_arrival_receipt_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_inbound_expectations_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inbound_repository.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('登记到货保存后直达审核页（收货单详情）', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeApi();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const WarehouseInboundExpectationsPage(),
        ),
        GoRoute(
          path: '/warehouse/inbound/receipts/new',
          builder: (_, state) => WarehouseArrivalReceiptPage(
            prefill: state.extra is ProcurementReceiptPrefill
                ? state.extra! as ProcurementReceiptPrefill
                : null,
          ),
        ),
        // 审核页桩：仅记录到达的单据 id（真实详情页走独立路由，不在本测试范围）。
        GoRoute(
          path: '/subcontract/receipts/:id',
          builder: (_, state) => _ReviewStub(id: state.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          employeeRepositoryProvider.overrideWithValue(
            DioEmployeeRepository(api),
          ),
          subcontractRepositoryProvider.overrideWith(
            (ref, type) => SubcontractRepository(api, type),
          ),
          procurementInboundRepositoryProvider.overrideWithValue(
            DioProcurementInboundRepository(api),
          ),
          departmentCodeIdMapProvider.overrideWith(
            (ref) async => <String, String>{},
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 任务中心：点「登记实际到货」进登记页。
    await tester.tap(find.text('登记实际到货'));
    await tester.pumpAndSettle();
    expect(find.text('登记实际到货 · 委外'), findsOneWidget);

    // 登记页：数量已按批准剩余预填（5），仓库已按建议仓预填，直接保存。
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 断言 1：保存请求打到了委外进仓单创建端点，且带收货人/明细。
    expect(api.lastCreatePath, '/subcontract/receipts');
    expect(api.lastCreateBody?['senderId'], 'emp-me');
    final items = api.lastCreateBody?['items'] as List?;
    expect(items, hasLength(1));
    expect((items!.first as Map)['qty'], 5);

    // 断言 2：保存成功后 pop(新单 id)，任务中心直达审核页（收货单详情）。
    expect(find.byType(_ReviewStub), findsOneWidget);
    expect(find.text('审核页:sc-receipt-1'), findsOneWidget);
  });
}

class _ReviewStub extends StatelessWidget {
  const _ReviewStub({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) => Scaffold(body: Text('审核页:$id'));
}

/// 固定当前登录人为 emp-me（收货人默认值来源）；无权限点（角标/计数不拉网）。
class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'user-me',
      code: 'USR-ME',
      name: '仓管员',
      roles: [],
      employeeId: 'emp-me',
    ),
  );
}

/// 内存假 API：只供本链路的几个端点，其余一律抛错（页面均有降级/静默处理）。
class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  String? lastCreatePath;
  Map<String, dynamic>? lastCreateBody;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/inbound/expectations') {
      return {
        'items': [_expectationJson()],
        'page': 1,
        'size': 20,
        'total': 1,
      };
    }
    if (path.contains('/count')) return const {'count': 0};
    throw ApiException('TEST_UNEXPECTED_GET', path);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/subcontract/receipts') {
      lastCreatePath = path;
      lastCreateBody = body as Map<String, dynamic>?;
      return const {'id': 'sc-receipt-1'};
    }
    if (path == '/warehouse/inbound/goods-profile-hints') {
      return const {'updated': 0};
    }
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }

  static Map<String, dynamic> _expectationJson() => {
    'id': 'expectation-1',
    'orderType': 'SUBCONTRACT',
    'orderId': 'order-1',
    'billNo': 'SC-PO-001',
    'supplierId': 'supplier-1',
    'supplierName': '测试委外商',
    'warehouseId': 'warehouse-1',
    'suggestedWarehouseId': 'warehouse-1',
    'suggestedWarehouseName': '成品仓',
    'status': 'OPEN',
    'remainingQty': 5,
    'allowedActions': ['CREATE_SUBCONTRACT_RECEIPT'],
    'items': [
      {
        'id': 'expectation-item-1',
        'orderItemId': 'order-item-1',
        'goodsId': 'goods-1',
        'goodsCode': 'G-001',
        'goodsName': '委外成品',
        'unitRate': 1,
        'orderedQty': 5,
        'acceptedQty': 0,
        'remainingQty': 5,
      },
    ],
  };
}
