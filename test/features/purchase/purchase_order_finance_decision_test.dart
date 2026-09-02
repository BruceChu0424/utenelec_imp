// 采购订货单详情页的财务审批入口边界测试。
//
// 即使当前账号是合格财务审核员、详情投影意外带有 APPROVE/REJECT，业务详情页
// 也只能展示待审状态；审批唯一入口是「财务 → 订货审批任务中心」。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
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
  'canEdit': true,
  'canDelete': true,
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

Future<void> _pump(
  WidgetTester tester,
  _RecordingApi api, {
  Size size = const Size(1200, 1800),
  Set<String> permissions = const {
    Perm.purchaseOrderView,
    Perm.purchaseOrderEdit,
    Perm.purchaseOrderDelete,
    Perm.purchaseOrderSubmitFinance,
    Perm.financeOrderApprovalView,
    Perm.financeOrderApprovalApprove,
    Perm.financeOrderApprovalReject,
  },
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        writeAllDocumentScope(DocumentDataScope.purchase),
        currentPermissionsProvider.overrideWithValue(permissions),
        purchaseRepositoryProvider(PurchaseDocType.order)
            .overrideWithValue(PurchaseRepository(api, PurchaseDocType.order)),
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
  for (final size in <Size>[const Size(1200, 1800), const Size(375, 812)]) {
    testWidgets('混合授权账号在 $size 的待审采购详情仍完全只读', (tester) async {
      final api = _RecordingApi();
      await _pump(tester, api, size: size);

      expect(find.text('删除'), findsNothing);
      expect(find.text('编辑'), findsNothing);
      expect(find.text('提交财务审核'), findsNothing);
      expect(
        find.byKey(const Key('purchase-order-finance-approve')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('purchase-order-finance-reject')),
        findsNothing,
      );
      expect(find.text('返回列表'), findsOneWidget);
      expect(find.textContaining('财务 → 订货审批任务中心'), findsOneWidget);
      expect(api.posts, isEmpty);
    });
  }

  testWidgets('finance-only 核单不显示业务历史并返回财务任务中心', (tester) async {
    await _pump(
      tester,
      _RecordingApi(),
      permissions: const {Perm.financeOrderApprovalView},
    );

    expect(find.text('查看历史'), findsNothing);
    expect(find.text('返回订货审批任务中心'), findsOneWidget);
  });
}
