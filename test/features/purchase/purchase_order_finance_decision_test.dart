import '../../support/native_detail_reader_overrides.dart';
// 采购订货单详情页的财务审批入口与打印边界测试。
//
// 即使当前账号是合格财务审核员、详情投影意外带有 APPROVE/REJECT，业务详情页
// 也只能展示待审状态(提示「审核期间仅可查看，财务将在订货审批中处理」)；审批唯一入口是「财务 → 订货审批任务中心」。
// 打印只读取有权可见的单据；待审也可打印，保留真实状态且不显示旧审核签名。
// 用户再次确认后才读取打印投影，打印不改变财务或业务状态。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

import '../../support/document_scope_capability_overrides.dart';

Map<String, dynamic> _orderDetail({
  required String? approvalStatus,
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
  if (approvalStatus != null)
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
  final List<String> printRequests = [];
  String? approvalStatus = 'PENDING';
  List<String> allowedActions = const ['APPROVE', 'REJECT'];
  int orderStatus = 0;
  ApiException? printError;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/purchase/orders/order-1/print-data') {
      printRequests.add(path);
      if (printError != null) throw printError!;
      return {
        'id': 'order-1',
        'billNo': 'PO-2026-001',
        'billDate': '2026-08-28',
        'companyName': '测试采购公司',
        'supplierName': '测试供应商',
        'makerName': '采购李四',
        'reviewerName': '财务王五',
        'financeApproved':
            orderStatus == kPurchaseStatusApproved &&
            approvalStatus == 'APPROVED',
        'statusLabel':
            orderStatus == kPurchaseStatusApproved &&
                approvalStatus == 'APPROVED'
            ? '财务已通过'
            : '等待财务审核',
        'lines': [
          {
            'id': 'i1',
            'goodsCode': 'G001',
            'goodsName': '测试采购货品',
            'physicalQty': '10',
            'unitName': '个',
          },
        ],
      };
    }
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
        ...nativeDetailReaderOverrides(),
        writeAllDocumentScope(DocumentDataScope.purchase),
        currentPermissionsProvider.overrideWithValue(permissions),
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
  for (final state in <({String name, int orderStatus, String? approval})>[
    (name: '草稿未提交', orderStatus: kPurchaseStatusDraft, approval: 'DRAFT'),
    (name: '待财务审核', orderStatus: kPurchaseStatusDraft, approval: 'PENDING'),
    (name: '财务退回', orderStatus: kPurchaseStatusDraft, approval: 'REJECTED'),
    (
      name: '草稿含过期通过投影',
      orderStatus: kPurchaseStatusDraft,
      approval: 'APPROVED',
    ),
    (name: '改量待复核', orderStatus: kPurchaseStatusApproved, approval: 'PENDING'),
    (
      name: '改量复核退回',
      orderStatus: kPurchaseStatusApproved,
      approval: 'REJECTED',
    ),
    (name: '已审但无财务通过证据', orderStatus: kPurchaseStatusApproved, approval: null),
    (name: '已反审', orderStatus: kPurchaseStatusReversed, approval: 'APPROVED'),
    (name: '已取消', orderStatus: kPurchaseStatusCanceled, approval: 'APPROVED'),
  ]) {
    testWidgets('${state.name}的采购详情允许核对后打印', (tester) async {
      final api = _RecordingApi()
        ..approvalStatus = state.approval
        ..orderStatus = state.orderStatus
        ..allowedActions = const [];
      await _pump(tester, api);

      final printButton = find.byKey(const Key('purchase-order-print'));
      expect(tester.widget<UtenButton>(printButton).onPressed, isNotNull);
      await tester.tap(printButton);
      await tester.pumpAndSettle();

      expect(find.text('确认打印采购单'), findsOneWidget);
      expect(api.printRequests, isEmpty);
      await tester.tap(find.text('确认打印'));
      await tester.pumpAndSettle();
      expect(api.printRequests, ['/purchase/orders/order-1/print-data']);
      expect(find.text('预览采购单 PO-2026-001'), findsOneWidget);
      expect(find.text('单据状态：等待财务审核'), findsOneWidget);
      expect(find.text('审核：—'), findsOneWidget);
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('财务通过的采购详情打印先确认，取消不读取打印单据', (tester) async {
    final api = _RecordingApi()
      ..approvalStatus = 'APPROVED'
      ..orderStatus = kPurchaseStatusApproved
      ..allowedActions = const [];
    await _pump(tester, api);

    final printButton = find.byKey(const Key('purchase-order-print'));
    expect(tester.widget<UtenButton>(printButton).onPressed, isNotNull);
    await tester.tap(printButton);
    await tester.pumpAndSettle();

    expect(find.text('确认打印采购单'), findsOneWidget);
    expect(find.textContaining('PO-2026-001'), findsWidgets);
    expect(find.text('确认打印'), findsOneWidget);
    expect(api.printRequests, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('确认打印采购单'), findsNothing);
    expect(api.printRequests, isEmpty);
    expect(tester.widget<UtenButton>(printButton).isLoading, isFalse);
    expect(tester.widget<UtenButton>(printButton).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('财务通过的采购详情确认打印后才读取单据并打开预览', (tester) async {
    final api = _RecordingApi()
      ..approvalStatus = 'APPROVED'
      ..orderStatus = kPurchaseStatusApproved
      ..allowedActions = const [];
    await _pump(tester, api);
    await tester.tap(find.byKey(const Key('purchase-order-print')));
    await tester.pumpAndSettle();

    expect(api.printRequests, isEmpty);
    await tester.tap(find.text('确认打印'));
    await tester.pumpAndSettle();

    expect(api.printRequests, ['/purchase/orders/order-1/print-data']);
    expect(find.text('确认打印采购单'), findsNothing);
    expect(find.text('预览采购单 PO-2026-001'), findsOneWidget);
    expect(find.text('审核：财务王五'), findsOneWidget);
    expect(
      find.byKey(const Key('purchase-print-preview-print')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认打印后服务端数据范围拒绝仍展示真实原因', (tester) async {
    final api = _RecordingApi()
      ..approvalStatus = 'APPROVED'
      ..orderStatus = kPurchaseStatusApproved
      ..allowedActions = const []
      ..printError = ApiException('FORBIDDEN', '采购单已不在可见范围，请刷新后重试');
    await _pump(tester, api);
    await tester.tap(find.byKey(const Key('purchase-order-print')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认打印'));
    await tester.pumpAndSettle();

    expect(api.printRequests, ['/purchase/orders/order-1/print-data']);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(PurchaseDocDetailPage)),
    ).read(appNotificationProvider);
    expect(notifications, hasLength(1));
    expect(notifications.single.kind, AppNotificationKind.error);
    expect(notifications.single.message, '采购单已不在可见范围，请刷新后重试');
    expect(find.byKey(const Key('purchase-print-preview-print')), findsNothing);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('purchase-order-print')))
          .isLoading,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  for (final status in [kPurchaseStatusCanceled, kPurchaseStatusReversed]) {
    testWidgets(
      'terminal purchase $status does not offer correction for historical rejection',
      (tester) async {
        final api = _RecordingApi()
          ..approvalStatus = 'REJECTED'
          ..orderStatus = status
          ..allowedActions = const [];
        await _pump(tester, api);
        expect(find.text('财务已退回，请修改后重新提交'), findsNothing);
        expect(find.text('重新提交财务'), findsNothing);
        expect(find.text('历史审批：财务已退回'), findsOneWidget);
        expect(find.text('编辑'), findsNothing);
        expect(api.posts, isEmpty);
      },
    );
  }

  testWidgets(
    'approved quantity review is shown as a review rather than first approval',
    (tester) async {
      final api = _RecordingApi()
        ..approvalStatus = 'REJECTED'
        ..orderStatus = kPurchaseStatusApproved
        ..allowedActions = const [];
      await _pump(tester, api);
      expect(find.text('改量财务已退回，请修订后重新提交'), findsOneWidget);
      expect(find.text('改量财务退回'), findsOneWidget);
      expect(api.posts, isEmpty);
    },
  );

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
      expect(find.textContaining('审核期间仅可查看，财务将在订货审批中处理'), findsOneWidget);
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
