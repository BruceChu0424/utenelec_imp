// 出货财务审核详情页（财务专用视图）测试——2026-09-12 从销售出货详情页拆分迁移：
// 认领机制、放行/退回决策、客户未分类阻断、认领失败重试等行为契约保持不变，
// 只是把宿主从共享详情页的弹窗搬到了 /finance/sales-shipment-audits/:id 专页。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_shipment_audit_review_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('review page previews customer facts before posting approval', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-finance-preview',
        'billNo': 'XS-20260912-001',
        'financeReviewPending': true,
        'salesConfirmed': true,
        'status': 0,
        'financeAudit': 0,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[
          {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 100},
        ],
      },
      claimSucceeds: true,
      financeAuditInfo: const {
        'shipmentId': 'shipment-finance-preview',
        'reviewRevision': 2,
        'contentHash': 'current-content',
        'financeAudit': 0,
        'clientName': '测试客户',
        'salesPaymentType': 'DEPOSIT',
        'settlementMethodName': '合同定金',
        'outstanding': '100.00',
        'creditFloor': '30.00',
        'overFloor': '70.00',
        'availablePrepaymentOriginal': '25.00',
        'availablePrepaymentLocal': '180.00',
      },
    );

    // 进入页面即完成认领并展示权威财务快照（不再需要先点「认领并审核」）。
    expect(api.postPaths.any((path) => path.endsWith('/claim')), isTrue);
    expect(
      api.getPaths,
      contains('/sales/shipments/shipment-finance-preview/finance-audit-info'),
    );
    expect(find.textContaining('XS-20260912-001'), findsWidgets);
    expect(find.textContaining('待财务审核'), findsOneWidget);
    expect(find.text('定金'), findsOneWidget);
    expect(find.text('合同定金'), findsOneWidget);
    expect(find.text('正式应收未收(本币)'), findsOneWidget);
    expect(find.text('铺底额(本币)'), findsOneWidget);
    expect(find.text('超出铺底额(本币)'), findsOneWidget);
    expect(find.text('70.00'), findsOneWidget);
    expect(find.text('可用预收(原币)'), findsOneWidget);
    expect(find.text('可用预收(本币)'), findsOneWidget);
    expect(find.text('25.00'), findsOneWidget);
    expect(find.text('180.00'), findsOneWidget);
    expect(find.textContaining('真实已审核到账'), findsOneWidget);
    expect(find.textContaining('绝不代表已经到账'), findsOneWidget);
    expect(
      api.postPaths.where((path) => path.endsWith('/finance-audit')),
      isEmpty,
    );

    final approve = find.byKey(const Key('finance-shipment-audit-approve'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(find.textContaining('系统将记录当前审核员并承担本次放行责任'), findsOneWidget);
    expect(
      api.postPaths.where((path) => path.endsWith('/finance-audit')),
      isEmpty,
    );
    final confirm = find.byKey(const Key('finance-shipment-audit-confirm'));
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(
      api.postPaths,
      contains('/sales/shipments/shipment-finance-preview/finance-audit'),
    );
  });

  testWidgets('finance claim network failure blocks decision and can retry', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-retry',
        'status': 0,
        'financeAudit': 0,
        'financeReviewPending': true,
        'salesConfirmed': true,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[],
      },
      financeAuditInfo: const {
        'shipmentId': 'shipment-retry',
        'reviewRevision': 1,
        'contentHash': 'retry-content',
        'salesPaymentType': 'CASH',
      },
    );
    // 认领失败：不放行/退回按钮（只有返回），提示重新认领。
    expect(
      find.byKey(const Key('finance-shipment-audit-approve')),
      findsNothing,
    );
    expect(find.textContaining('重新认领并刷新'), findsOneWidget);
    expect(
      api.postPaths.where((path) => path.endsWith('/finance-audit')),
      isEmpty,
    );
    api.claimSucceeds = true;
    await tester.tap(find.text('重新认领并刷新'));
    await tester.pumpAndSettle();
    final approve = find.byKey(const Key('finance-shipment-audit-approve'));
    expect(approve, findsOneWidget);
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finance-shipment-audit-confirm')));
    await tester.pumpAndSettle();
    expect(
      api.postPaths.where((path) => path.endsWith('/finance-audit')),
      hasLength(1),
    );
  });

  testWidgets('shipment finance lost lease pauses decision before posting', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-lost',
        'status': 0,
        'financeAudit': 0,
        'financeReviewPending': true,
        'salesConfirmed': true,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[],
      },
      claimSucceeds: true,
      financeAuditInfo: const {
        'shipmentId': 'shipment-lost',
        'reviewRevision': 1,
        'contentHash': 'lost-content',
        'salesPaymentType': 'CASH',
      },
    );
    api.failHeartbeat = true;
    final approve = find.byKey(const Key('finance-shipment-audit-approve'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finance-shipment-audit-confirm')));
    await tester.pumpAndSettle();
    expect(api.postPaths.any((path) => path.endsWith('/heartbeat')), isTrue);
    expect(
      api.postPaths.where((path) => path.endsWith('/finance-audit')),
      isEmpty,
    );
  });

  testWidgets(
    'unclassified customer blocks finance release with recovery path',
    (tester) async {
      final api = await _pumpReviewPage(
        tester,
        detail: const {
          'id': 'shipment-unclassified',
          'financeReviewPending': true,
          'salesConfirmed': true,
          'status': 0,
          'financeAudit': 0,
          'warehouseWorkStatus': 'PENDING_PICK',
          'items': <Map<String, dynamic>>[
            {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 100},
          ],
        },
        // 无 client:edit → 不出现「去客户资料」，只提示联系有权限人员。
        permissions: const {Perm.financeShipmentAudit, Perm.clientView},
        claimSucceeds: true,
        financeAuditInfo: const {
          'shipmentId': 'shipment-unclassified',
          'reviewRevision': 0,
          'contentHash': 'unclassified-content',
          'financeAudit': 0,
          'clientName': '待分类客户',
          'salesPaymentType': '',
          'outstanding': '100.00',
          'creditFloor': '0',
          'overFloor': '100.00',
          'availablePrepaymentOriginal': '0',
          'availablePrepaymentLocal': '0',
        },
      );

      expect(
        find.byKey(const Key('finance-audit-classification-block')),
        findsOneWidget,
      );
      expect(find.textContaining('联系有客户资料维护权限的人员'), findsOneWidget);
      expect(
        find.byKey(const Key('finance-audit-open-client-master')),
        findsNothing,
      );
      // 放行按钮禁用（点不出 POST）；退回销售不受分类阻断。
      final approve = find.byKey(const Key('finance-shipment-audit-approve'));
      expect(approve, findsOneWidget);
      await tester.ensureVisible(approve);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('finance-shipment-audit-confirm')),
        findsNothing,
      );
      expect(
        api.postPaths.where((path) => path.endsWith('/finance-audit')),
        isEmpty,
      );
      expect(
        find.byKey(const Key('finance-shipment-audit-reject')),
        findsOneWidget,
      );
    },
  );

  testWidgets('reject requires reason and posts finance-audit-reject', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-reject-flow',
        'billNo': 'XS-REJECT-1',
        'financeReviewPending': true,
        'salesConfirmed': true,
        'status': 0,
        'financeAudit': 0,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[],
      },
      claimSucceeds: true,
      financeAuditInfo: const {
        'shipmentId': 'shipment-reject-flow',
        'reviewRevision': 3,
        'contentHash': 'reject-content',
        'salesPaymentType': 'MONTHLY',
      },
    );
    final reject = find.byKey(const Key('finance-shipment-audit-reject'));
    await tester.ensureVisible(reject);
    await tester.tap(reject);
    await tester.pumpAndSettle();
    final submit = find.byKey(
      const Key('finance-shipment-audit-reject-submit'),
    );
    // 原因为空时提交被拦（文案进输入框 ⓘ Tooltip，不发起 POST）。
    await tester.tap(submit);
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && widget.message?.contains('请填写退回原因') == true,
      ),
      findsOneWidget,
    );
    expect(
      api.postPaths.where((path) => path.endsWith('/finance-audit-reject')),
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('finance-shipment-audit-reject-reason')),
      '结账方式有误，请改为月结',
    );
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
      api.postPaths,
      contains('/sales/shipments/shipment-reject-flow/finance-audit-reject'),
    );
  });
}

Future<_ReviewApi> _pumpReviewPage(
  WidgetTester tester, {
  required Map<String, dynamic> detail,
  Map<String, dynamic>? financeAuditInfo,
  bool claimSucceeds = false,
  Set<String> permissions = const {Perm.financeShipmentAudit},
  Size surfaceSize = const Size(1500, 1100),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _ReviewApi(
    detail,
    financeAuditInfo: financeAuditInfo,
    claimSucceeds: claimSucceeds,
  );
  final router = GoRouter(
    initialLocation: '/finance/sales-shipment-audits/${detail['id']}',
    routes: [
      GoRoute(
        path: '/finance/sales-shipment-audits',
        builder: (_, _) => const Scaffold(body: SizedBox.shrink()),
      ),
      GoRoute(
        path: '/finance/sales-shipment-audits/:id',
        builder: (_, state) => FinanceSalesShipmentAuditReviewPage(
          id: state.pathParameters['id']!,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

class _ReviewApi extends ApiClient {
  _ReviewApi(this.detail, {this.financeAuditInfo, this.claimSucceeds = false})
    : super(Dio());
  bool claimSucceeds;
  bool failHeartbeat = false;

  final Map<String, dynamic> detail;
  final Map<String, dynamic>? financeAuditInfo;
  final List<String> getPaths = [];
  final List<String> postPaths = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    getPaths.add(path);
    if (path.endsWith('/finance-audit-info')) {
      return {
        'commercialSnapshot': jsonEncode({
          'header': <String, dynamic>{},
          'items': detail['items'] ?? <dynamic>[],
        }),
        ...?financeAuditInfo,
      };
    }
    return detail;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postPaths.add(path);
    if (path.startsWith('/task-claims/') &&
        (path.endsWith('/claim') || path.endsWith('/heartbeat'))) {
      if (!claimSucceeds || (path.endsWith('/heartbeat') && failHeartbeat)) {
        throw StateError('test lease unavailable');
      }
      return {
        'claimId': 'shipment-lease',
        'targetType': 'SALES_SHIPMENT_FINANCE_AUDIT',
        'targetKey': detail['id'],
        'claimedBy': 'reviewer',
        'claimedByName': '财务经办',
        'claimedByMe': true,
        'claimedAt': DateTime.now().toIso8601String(),
        'leaseUntil': DateTime.now()
            .add(const Duration(minutes: 30))
            .toIso8601String(),
      };
    }
    if (path.endsWith('/finance-audit') ||
        path.endsWith('/finance-audit-reject')) {
      return <String, dynamic>{...?financeAuditInfo, 'financeAudit': 1};
    }
    throw StateError('unsupported test POST: $path');
  }

  @override
  Future<void> delete(String path) async {}

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/currencies/dict') {
      return const [
        {'id': 'currency-usd', 'name': '美元'},
      ];
    }
    return const [];
  }
}
