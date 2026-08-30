// 采购订货单详情页页内财务审批测试。
//
// 背景：财务审核员从「订货审批任务中心」点进具体订货单详情时，此前底栏只有
// 「返回列表」；V426 起待审且服务端 allowedActions 含 APPROVE/REJECT 的，
// 详情页直接给出「驳回 / 审批通过」（与任务中心共用同一端点和责任留痕）。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

Map<String, dynamic> _orderDetail({
  required String approvalStatus,
  required List<String> allowedActions,
  int status = 0,
}) => {
  'id': 'order-1',
  'makerId': 'maker-1',
  'billNo': 'PO-2026-001',
  'billDate': '2026-08-28',
  'makerName': '采购李四',
  'createdAt': '2026-08-28T10:00:00+08:00',
  'supplierId': 'sup-1',
  'currencyId': 'cny',
  'exchangeRate': 1,
  'status': status,
  'totalLocal': 50.0,
  'canEdit': false,
  'canDelete': false,
  'canReverse': false,
  'financeApproval': {
    'caseId': 'case-1',
    'status': approvalStatus,
    'attempt': 1,
    'version': 3,
    'allowedActions': allowedActions,
  },
  'items': [
    {
      'id': 'i1',
      'goodsId': 'g1',
      'colorId': 'c1',
      'unitId': 'u1',
      'qty': 10,
      'price': 5,
      'amountLocal': 50,
    },
  ],
};

class _RecordingApi extends ApiClient {
  _RecordingApi()
    : super(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api')));

  final List<({String method, String path, Object? body})> posts = [];
  String approvalStatus = 'PENDING';
  List<String> allowedActions = const ['APPROVE', 'REJECT'];
  int orderStatus = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/purchase/orders/order-1')) {
      return _orderDetail(
        approvalStatus: approvalStatus,
        allowedActions: allowedActions,
        status: orderStatus,
      );
    }
    return <String, dynamic>{'items': <Object?>[]};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add((method: 'POST', path: path, body: body));
    if (path.endsWith('/approve')) {
      approvalStatus = 'APPROVED';
      allowedActions = const [];
      orderStatus = 1;
    } else if (path.endsWith('/reject')) {
      approvalStatus = 'REJECTED';
      allowedActions = const [];
    }
    return _orderDetail(
      approvalStatus: approvalStatus,
      allowedActions: allowedActions,
      status: orderStatus,
    );
  }
}

Future<void> _pump(WidgetTester tester, _RecordingApi api) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        writeAllDocumentScope(DocumentDataScope.purchase),
        purchaseRepositoryProvider(
          PurchaseDocType.order,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.order)),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: const MaterialApp(
        home: PurchaseDocDetailPage(
          docType: PurchaseDocType.order,
          id: 'order-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('待审订货单对持权审核员显示驳回/审批通过，而非仅返回列表', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api);

    expect(
      find.byKey(const Key('purchase-order-finance-reject')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('purchase-order-finance-approve')),
      findsOneWidget,
    );
    expect(find.text('返回列表'), findsNothing);
  });

  testWidgets('无办理权限（allowedActions 空）时保持只读，仅返回列表', (tester) async {
    final api = _RecordingApi()..allowedActions = const [];
    await _pump(tester, api);

    expect(
      find.byKey(const Key('purchase-order-finance-approve')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('purchase-order-finance-reject')),
      findsNothing,
    );
    expect(find.text('返回列表'), findsOneWidget);
  });

  testWidgets('页内审批通过走订货审批端点并携带 expectedVersion', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api);

    await tester.tap(find.byKey(const Key('purchase-order-finance-approve')));
    await tester.pumpAndSettle();

    // 审核责任确认框：责任提示 + 业务影响说明。
    expect(find.text('审批通过订货单'), findsOneWidget);
    expect(
      find.byKey(const Key('reviewer-responsibility-notice')),
      findsOneWidget,
    );

    await tester.tap(find.text('确认通过'));
    await tester.pumpAndSettle();

    expect(api.posts, hasLength(1));
    expect(api.posts.single.path, '/purchase/orders/order-1/approve');
    expect(api.posts.single.body, containsPair('expectedVersion', 3));

    // 决策成功后刷新投影：按钮退场，横幅切换为已通过。
    expect(
      find.byKey(const Key('purchase-order-finance-approve')),
      findsNothing,
    );
    expect(find.text('财务已通过'), findsOneWidget);
  });

  testWidgets('页内驳回要求必填退回原因并携带 expectedVersion', (tester) async {
    final api = _RecordingApi();
    await _pump(tester, api);

    await tester.tap(find.byKey(const Key('purchase-order-finance-reject')));
    await tester.pumpAndSettle();

    expect(find.text('驳回订货单'), findsOneWidget);
    expect(find.text('确认驳回'), findsOneWidget);

    // 原因为空时确认按钮禁用；填写后可提交。
    final confirm = find.widgetWithText(FilledButton, '确认驳回');
    expect(
      tester.widget<FilledButton>(confirm).enabled,
      isFalse,
      reason: '退回原因为空时不得提交',
    );
    await tester.enterText(find.byType(TextField), '单价与合同不符，请修改后重提');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).enabled, isTrue);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(api.posts, hasLength(1));
    expect(api.posts.single.path, '/purchase/orders/order-1/reject');
    expect(api.posts.single.body, containsPair('expectedVersion', 3));
    expect(api.posts.single.body, containsPair('reason', '单价与合同不符，请修改后重提'));
    expect(
      find.byKey(const Key('purchase-order-finance-reject')),
      findsNothing,
    );
  });
}
