// 到货登记「登记并送检」一步完成的导航链路 widget 测试。
//
// 覆盖 2026-08-27 的流程简化：预计到货任务中心点「登记实际到货」→ 登记页
// 「登记并送检」（确认框）→ POST /warehouse/inbound/arrivals（服务端按订货单回填
// 币族并同事务审核）→ pop(结果) 回任务中心就地刷新并提示下一步——全程不再跳
// 采购/委外收货单详情页。用委外（SUBCONTRACT）类型：无需采购员，表单最小可提交。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_arrival_receipt_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_inbound_expectations_page.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inbound_repository.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

/// 双击指定行（两次点按间隔 50ms，落在 350ms 手动双击判定窗内）——
/// 任务中心表格行双击 = 打开到货详情弹窗。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets('登记并送检丢响应重试复用原 key，回任务中心且不跳收货单详情', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeApi(failFirstArrival: true);
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
        // 旧流程会自动跳审核页（收货单详情）；新流程不应到达这里，桩用于反向断言。
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
          procurementInboundRepositoryProvider.overrideWithValue(
            DioProcurementInboundRepository(api),
          ),
          departmentCodeIdMapProvider.overrideWith(
            (ref) async => <String, String>{},
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          // 顶部通知宿主（与 app.dart 同构）：成功提示条需要它才会渲染。
          builder: (context, child) => Stack(
            children: [
              child!,
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(useSafeArea: false),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 任务中心：双击行打开到货详情，点「登记实际到货」进登记页。
    await _doubleTapRow(tester, find.text('SC-PO-001'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记实际到货'));
    await tester.pumpAndSettle();
    expect(find.text('登记实际到货 · 委外'), findsOneWidget);
    expect(
      find.byKey(const Key('warehouse-arrival-lines-grid')),
      findsOneWidget,
    );

    final suggestedStatus = find.byKey(
      const Key('warehouse-arrival-suggested-warehouse-status'),
    );
    expect(suggestedStatus, findsOneWidget);
    expect(
      tester.widget<Semantics>(suggestedStatus).properties.liveRegion,
      isTrue,
    );
    expect(find.textContaining('已按物料分析目标仓预填'), findsOneWidget);

    await tester.tap(find.byKey(const Key('warehouse-arrival-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原料仓').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('不会计入原物料分析目标仓'), findsOneWidget);
    expect(find.textContaining('计划部仍会显示缺料'), findsOneWidget);

    await tester.tap(find.byKey(const Key('warehouse-arrival-warehouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('成品仓').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('不会计入原物料分析目标仓'), findsNothing);
    expect(find.textContaining('已按物料分析目标仓预填'), findsOneWidget);

    // 登记页：数量已按批准剩余预填（5），仓库已按建议仓预填，直接登记并送检。
    await tester.tap(find.text('登记并送检'));
    await tester.pumpAndSettle();
    // 审核责任确认框 → 确认登记送检。
    expect(find.text('确认登记送检'), findsOneWidget);
    await tester.tap(find.text('确认登记送检'));
    // 第一次模拟服务端已可能提交、但客户端丢失响应。页面必须留在原处并保留同一个 key。
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('登记实际到货 · 委外'), findsOneWidget);
    expect(api.arrivalPostBodies, hasLength(1));
    final firstKey = api.arrivalPostBodies.single['idempotencyKey'];
    expect(firstKey, isA<String>());
    expect(
      firstKey as String,
      matches(r'^warehouse-arrival-create-[0-9a-f]{16}$'),
    );

    // 原页面原动作重试：服务端以 maker+key+hash 回放原结果，不再造第二张收货单。
    await tester.tap(find.text('登记并送检'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认登记送检'));
    // 有界推进（通知条默认 3.2s 自动消失，不能 pumpAndSettle 到底）：
    // 覆盖重试 POST → pop → 任务中心刷新。通知队列仍可能显示首个网络错误，
    // 不把瞬时通知动画作为幂等业务结果的判据。
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 断言 1：请求打到「一步登记」端点，orderType=委外、收货人/明细齐备、不带价格。
    expect(api.lastPostPath, '/warehouse/inbound/arrivals');
    expect(api.lastPostBody?['orderType'], 'SUBCONTRACT');
    expect(api.lastPostBody?['receiverEmployeeId'], 'emp-me');
    expect(api.lastPostBody?['idempotencyKey'], firstKey);
    expect(api.arrivalPostBodies, hasLength(2));
    expect(
      api.arrivalPostBodies.map((body) => body['idempotencyKey']).toSet(),
      {firstKey},
    );
    final items = api.lastPostBody?['items'] as List?;
    expect(items, hasLength(1));
    final item = items!.first as Map;
    expect(item['qty'], 5);
    expect(item.containsKey('price'), isFalse);

    // 断言 2：回任务中心（不再直达审核页）；原结果由第二次同-key 响应收敛。
    expect(find.byType(_ReviewStub), findsNothing);
    expect(find.text('预计到货任务中心'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('已登记待送检的任务卡「继续送检」走一步完成端点，不进采购/委外单据页', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeApi(pendingDraftReceiptIds: const ['sc-receipt-9']);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const WarehouseInboundExpectationsPage(),
        ),
        // 旧流程会跳审核页（收货单详情）；新流程不应到达这里，桩用于反向断言。
        GoRoute(
          path: '/subcontract/receipts/:id',
          builder: (_, state) => _ReviewStub(id: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/warehouse/inbound/arrival-exceptions',
          builder: (_, _) => const _ExceptionsStub(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          procurementInboundRepositoryProvider.overrideWithValue(
            DioProcurementInboundRepository(api),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => Stack(
            children: [
              child!,
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(useSafeArea: false),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 断点恢复：任务停在「已登记 · 待送检」，双击行开详情点「继续送检」→ 责任确认框 → 完成。
    expect(find.text('已登记 · 待送检'), findsOneWidget);
    await _doubleTapRow(tester, find.text('SC-PO-001'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续送检'));
    await tester.pumpAndSettle();
    expect(find.text('确认送检'), findsOneWidget);
    await tester.tap(find.text('确认送检'));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 断言 1：请求打到「完成登记」端点（按草稿单 id），不进收货单详情页。
    expect(
      api.lastPostPath,
      '/warehouse/inbound/arrivals/sc-receipt-9/complete',
    );
    expect(find.byType(_ReviewStub), findsNothing);

    // 断言 2：回任务中心并提示下一步。
    expect(find.text('预计到货任务中心'), findsOneWidget);
    expect(find.textContaining('品质部检验合格后自动入库'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('已送检任务停在「待品质检验」步骤，无操作按钮只读跟进', (tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _FakeApi(inspectionPendingReceipts: 2);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_TestSessionNotifier.new),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          procurementInboundRepositoryProvider.overrideWithValue(
            DioProcurementInboundRepository(api),
          ),
        ],
        child: const MaterialApp(home: WarehouseInboundExpectationsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已送检 · 待品质检验'), findsOneWidget);
    // 只读步骤：双击进详情，按钮禁用，不给仓库多余操作。
    await _doubleTapRow(tester, find.text('SC-PO-001'));
    await tester.pumpAndSettle();
    expect(find.text('待品质检验(2)'), findsOneWidget);
    expect(find.textContaining('检验合格后自动入库存，仓库无需操作'), findsOneWidget);
    final button = tester.widget<UtenButton>(
      find.byKey(const Key('create-receipt-expectation-1')),
    );
    expect(button.onPressed, isNull);
  });
}

class _ReviewStub extends StatelessWidget {
  const _ReviewStub({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) => Scaffold(body: Text('审核页:$id'));
}

class _ExceptionsStub extends StatelessWidget {
  const _ExceptionsStub();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('到货异常任务中心'));
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
  _FakeApi({
    this.pendingDraftReceiptIds = const [],
    this.inspectionPendingReceipts = 0,
    this.failFirstArrival = false,
  }) : super(Dio());

  /// 待恢复场景：任务挂着的草稿收货单 id 列表。
  final List<String> pendingDraftReceiptIds;

  /// 待品质场景：待品质放行的收货单张数（任务转 CLOSED 后仍留在列表）。
  final int inspectionPendingReceipts;

  /// 模拟服务端可能已提交但客户端未收到响应；第二次用原 key 重试。
  final bool failFirstArrival;

  String? lastPostPath;
  Map<String, dynamic>? lastPostBody;
  final List<Map<String, dynamic>> arrivalPostBodies = [];

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
    if (path == '/master/warehouses/dict') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓'},
        {'id': 'warehouse-2', 'name': '原料仓'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/inbound/arrivals') {
      lastPostPath = path;
      lastPostBody = Map<String, dynamic>.from(body! as Map);
      arrivalPostBodies.add(lastPostBody!);
      if (failFirstArrival && arrivalPostBodies.length == 1) {
        throw NetworkException('响应中断，请使用原请求重试');
      }
      return const {
        'outcome': 'SUBMITTED_FOR_INSPECTION',
        'receiptId': 'sc-receipt-1',
        'receiptBillNo': 'SC-SR-001',
      };
    }
    if (path.startsWith('/warehouse/inbound/arrivals/') &&
        path.endsWith('/complete')) {
      lastPostPath = path;
      return const {
        'outcome': 'SUBMITTED_FOR_INSPECTION',
        'receiptId': 'sc-receipt-9',
        'receiptBillNo': 'SC-SR-009',
      };
    }
    if (path == '/warehouse/inbound/goods-profile-hints') {
      return const {'updated': 0};
    }
    throw ApiException('TEST_UNEXPECTED_POST', path);
  }

  Map<String, dynamic> _expectationJson() {
    // 三种形态：待登记（默认）/ 已登记待送检（挂草稿）/ 已送检待品质（CLOSED 未放行）。
    final registered = pendingDraftReceiptIds.isNotEmpty;
    final awaitingQuality = inspectionPendingReceipts > 0;
    Map<String, dynamic> itemQty(num ordered, num accepted) => {
      'id': 'expectation-item-1',
      'orderItemId': 'order-item-1',
      'goodsId': 'goods-1',
      'goodsCode': 'G-001',
      'goodsName': '委外成品',
      'unitRate': 1,
      'orderedQty': ordered,
      'acceptedQty': accepted,
      'remainingQty': ordered,
      'registeredQty': registered ? ordered : 0,
    };
    return {
      'id': 'expectation-1',
      'orderType': 'SUBCONTRACT',
      'orderId': 'order-1',
      'billNo': 'SC-PO-001',
      'supplierId': 'supplier-1',
      'supplierName': '测试委外商',
      'warehouseId': 'warehouse-1',
      'suggestedWarehouseId': 'warehouse-1',
      'suggestedWarehouseName': '成品仓',
      'status': awaitingQuality ? 'CLOSED' : 'OPEN',
      'remainingQty': 5,
      'registeredQty': registered ? 5 : 0,
      'allowedActions': ['CREATE_SUBCONTRACT_RECEIPT'],
      'draftReceiptIds': pendingDraftReceiptIds,
      'pendingInspectionReceipts': inspectionPendingReceipts,
      'openArrivalExceptions': 0,
      'items': [itemQty(5, awaitingQuality ? 5 : 0)],
    };
  }
}
