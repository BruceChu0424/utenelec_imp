// 委外订货详情页（财务待审）回归测试。
//
// 回归背景：底操作栏曾用 Center(Wrap(...)) 包裹按钮——Center/Align 在
// Scaffold bottomNavigationBar 的宽松约束下会撑满全部可用高度，把 body
// 挤成 0 高，导致详情/标题内容整片消失、只剩两个按钮。修复为 Wrap 自收缩
// + WrapAlignment.center。本测试锁定：body 高度必须大于 0 且完整渲染。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart' as mn;
import 'package:uten_imp/shared/providers/session_provider.dart';

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _pendingOrderDetail() => {
  'id': 'order-1',
  'billNo': 'WO-2026-001',
  'billDate': '2026-08-05',
  'makerName': '张三',
  'createdAt': '2026-08-05T10:00:00+08:00',
  'supplierId': 'sup-1',
  'warehouseId': 'wh-1',
  'currencyId': 'cny',
  'status': 0,
  'totalLocal': 50.0,
  'financeApproval': {
    'caseId': 'case-1',
    'status': 'PENDING',
    'attempt': 1,
    'version': 3,
    'assigneeName': '财务负责人',
    'allowedActions': ['APPROVE', 'REJECT'],
  },
  'items': [
    {
      'id': 'i1',
      'goodsId': 'g1',
      'colorId': 'c1',
      'unitId': 'u1',
      'qty': 10,
      'price': 5,
    },
  ],
};

Map<String, dynamic> _draftReceiptDetail() => {
  'id': 'receipt-1',
  'billNo': 'WR-2026-001',
  'billDate': '2026-08-22',
  'makerName': '仓管员',
  'createdAt': '2026-08-22T10:00:00+08:00',
  'supplierId': 'sup-1',
  'warehouseId': 'wh-1',
  'status': 0,
  'totalLocal': 50.0,
  'items': [
    {
      'id': 'ri1',
      'goodsId': 'g1',
      'colorId': 'c1',
      'unitId': 'u1',
      'qty': 10,
      'price': 5,
    },
  ],
};

class _WarehouseReviewerSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'warehouse-reviewer',
      code: 'WH001',
      name: '仓管王五',
      roles: [],
    ),
  );
}

void main() {
  testWidgets('委外订货详情（财务待审）渲染标题、表头、明细与审批按钮，body 不被底栏挤没', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _api((request) {
      if (request.path.contains('/subcontract/orders/order-1')) {
        return _pendingOrderDetail();
      }
      return <Object?>[]; // 字典/名称接口一律空列表
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subcontractRepositoryProvider(
            SubcontractDocType.order,
          ).overrideWithValue(
            SubcontractRepository(api, SubcontractDocType.order),
          ),
          mn.masterNameServiceProvider.overrideWithValue(
            mn.MasterNameService(api),
          ),
        ],
        child: const MaterialApp(
          home: SubcontractDocDetailPage(
            docType: SubcontractDocType.order,
            id: 'order-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '页面构建期间不应抛异常');

    // 核心回归断言：body（外层 ListView）必须拿到非零高度。
    // 页面内嵌表格也含 ListView，取全部实例中的最大高度。
    final maxListHeight = tester
        .renderObjectList<RenderBox>(find.byType(ListView))
        .map((r) => r.size.height)
        .fold<double>(0, (a, b) => a > b ? a : b);
    expect(maxListHeight, greaterThan(400), reason: '底操作栏不得撑满高度把 body 挤成 0');

    // 顶栏与返回键
    expect(find.text('委外订货单详情'), findsOneWidget);
    expect(find.text('查看历史'), findsOneWidget);

    // 表头信息
    expect(find.text('WO-2026-001'), findsOneWidget);
    expect(find.text('单据号'), findsOneWidget);
    expect(find.text('等待财务审核组审核'), findsOneWidget);

    // 财务审批横幅
    expect(find.text('等待财务审核组处理'), findsOneWidget);

    // 明细表
    expect(find.text('明细 (1)'), findsOneWidget);
    expect(find.text('10.00'), findsOneWidget);

    // 审批动作已收敛到「财务 → 订货审批任务中心」：订货详情页（采购/委外视角）
    // 只读展示等待状态，不得出现审批按钮（即使当前账号有审核资格）。
    expect(find.text('退回修改'), findsNothing);
    expect(find.text('财务审核通过'), findsNothing);
  });

  testWidgets('委外进仓直接审核确认显示当前审核员责任', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final api = _api((request) {
      if (request.path.contains('/subcontract/receipts/receipt-1')) {
        return _draftReceiptDetail();
      }
      return <Object?>[];
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const {
            Perm.subcontractReceiptApprove,
          }),
          sessionProvider.overrideWith(_WarehouseReviewerSessionNotifier.new),
          subcontractRepositoryProvider(
            SubcontractDocType.receipt,
          ).overrideWithValue(
            SubcontractRepository(api, SubcontractDocType.receipt),
          ),
          mn.masterNameServiceProvider.overrideWithValue(
            mn.MasterNameService(api),
          ),
        ],
        child: const MaterialApp(
          home: SubcontractDocDetailPage(
            docType: SubcontractDocType.receipt,
            id: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('审核'), findsOneWidget);
    await tester.tap(find.text('审核'));
    await tester.pumpAndSettle();

    expect(find.text('审核员：仓管王五（WH001）'), findsOneWidget);
    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
    );
  });
}
