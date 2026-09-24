// 出货财务审核详情页（财务专用视图）测试——2026-09-12 从销售出货详情页拆分迁移：
// 认领机制、放行/退回决策、客户未分类阻断、认领失败重试等行为契约保持不变，
// 只是把宿主从共享详情页的弹窗搬到了 /finance/sales-shipment-audits/:id 专页。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_shipment_audit_review_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'a shipment resubmission identifies the modification above its bill number',
    (tester) async {
      await _pumpReviewPage(
        tester,
        detail: const {
          'id': 'shipment-revised',
          'billNo': 'XS-MODIFIED',
          'status': 0,
          'financeAudit': 0,
          'financeReviewPending': true,
          'salesConfirmed': true,
          'warehouseWorkStatus': 'PENDING_PICK',
          'items': [
            {'id': 'line', 'qty': 2, 'price': 100},
          ],
        },
        claimSucceeds: true,
        financeAuditInfo: {
          'shipmentId': 'shipment-revised',
          'reviewRevision': 2,
          'contentHash': 'revised',
          'previousCommercialSnapshot': jsonEncode({
            'header': <String, dynamic>{},
            'items': [
              {'id': 'line', 'qty': 1, 'price': 100},
            ],
          }),
        },
      );
      expect(find.text('出货单修改'), findsOneWidget);
      expect(find.text('XS-MODIFIED'), findsWidgets);
    },
  );

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
    expect(find.textContaining('结账方式来自本单'), findsOneWidget);
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

  // V630：客户货款类别标签退役——放行只看本单结账方式/应收/铺底/预收，不再被
  // 「客户未分类」阻断，快照卡也不再出现阻断条与「去客户资料」入口。
  testWidgets('finance release is not gated by any customer label', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-no-label',
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
        'shipmentId': 'shipment-no-label',
        'reviewRevision': 0,
        'contentHash': 'no-label-content',
        'financeAudit': 0,
        'clientName': '汇款客户',
        'settlementMethodName': '汇款',
        'outstanding': '100.00',
        'creditFloor': '0',
        'overFloor': '100.00',
        'availablePrepaymentOriginal': '0',
        'availablePrepaymentLocal': '0',
      },
    );

    expect(find.text('结账方式'), findsOneWidget);
    expect(find.text('汇款'), findsOneWidget);
    expect(find.textContaining('货款类别'), findsNothing);
    expect(find.textContaining('尚未完成销售货款分类'), findsNothing);
    expect(
      find.byKey(const Key('finance-audit-classification-block')),
      findsNothing,
    );
    final approve = find.byKey(const Key('finance-shipment-audit-approve'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finance-shipment-audit-confirm')));
    await tester.pumpAndSettle();
    expect(
      api.postPaths,
      contains('/sales/shipments/shipment-no-label/finance-audit'),
    );
  });

  testWidgets(
    'missing master rate asks finance to fill the recognition rate at release',
    (tester) async {
      // V632：主档参考汇率没维护不再禁用放行——财务在放行时填记账汇率，空着放行才被拦。
      final api = await _pumpReviewPage(
        tester,
        detail: const {
          'id': 'shipment-no-rate',
          'billNo': 'XS-NO-RATE',
          'financeReviewPending': true,
          'salesConfirmed': true,
          'status': 0,
          'financeAudit': 0,
          'warehouseWorkStatus': 'PENDING_PICK',
          'currencyId': 'currency-usd',
          'totalOriginal': 1000,
          'items': <Map<String, dynamic>>[
            {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 10, 'price': 100},
          ],
        },
        claimSucceeds: true,
        financeAuditInfo: const {
          'shipmentId': 'shipment-no-rate',
          'reviewRevision': 0,
          'contentHash': 'no-rate-content',
          'financeAudit': 0,
          'clientName': '美金客户',
          'settlementMethodName': '汇款',
          'currencyName': '美金',
          'financeRate': '0.000000',
          'financeRateReady': false,
          'baseCurrency': false,
          'shipmentExchangeRate': '',
          'suggestedExchangeRate': '',
          'outstanding': '0',
          'creditFloor': '0',
          'overFloor': '0',
          'availablePrepaymentOriginal': '0',
          'availablePrepaymentLocal': '0',
        },
      );

      expect(find.text('主档参考汇率(美金)'), findsOneWidget);
      expect(find.text('未维护'), findsOneWidget);
      expect(find.byKey(const Key('finance-audit-rate-block')), findsOneWidget);
      final rateField = find.byKey(const Key('finance-audit-exchange-rate'));
      expect(rateField, findsOneWidget);
      expect(tester.widget<TextField>(rateField).controller!.text, isEmpty);
      final approve = find.byKey(const Key('finance-shipment-audit-approve'));
      expect(
        tester.widget<UtenButton>(approve).onPressed,
        isNotNull,
        reason: '主档没维护不再禁用放行，改由财务填汇率',
      );
      // 空着放行：被拦在客户端，不发 POST。
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
      // 填了记账汇率：确认弹窗复述汇率与折合本币参考值，POST 带 exchangeRate。
      await tester.enterText(rateField, '7.2');
      await tester.pumpAndSettle();
      await tester.ensureVisible(approve);
      await tester.tap(approve);
      await tester.pumpAndSettle();
      final rateLine = find.byKey(
        const Key('finance-shipment-audit-confirm-rate'),
      );
      expect(rateLine, findsOneWidget);
      expect(
        tester.widget<Text>(rateLine).data,
        allOf(contains('记账汇率 7.2'), contains('7200.00')),
      );
      await tester.tap(find.byKey(const Key('finance-shipment-audit-confirm')));
      await tester.pumpAndSettle();
      expect(
        api.postPaths,
        contains('/sales/shipments/shipment-no-rate/finance-audit'),
      );
      final body =
          api.postBodies['/sales/shipments/shipment-no-rate/finance-audit']
              as Map<String, dynamic>;
      expect(body['exchangeRate'], '7.2');
    },
  );

  testWidgets('master reference rate is prefilled and submitted as-is', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-master-rate',
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
        'shipmentId': 'shipment-master-rate',
        'reviewRevision': 0,
        'contentHash': 'master-rate-content',
        'financeAudit': 0,
        'clientName': '美金客户',
        'currencyName': '美金',
        'financeRate': '7.000000',
        'financeRateReady': true,
        'baseCurrency': false,
        'shipmentExchangeRate': '',
        'suggestedExchangeRate': '7',
      },
    );
    expect(find.byKey(const Key('finance-audit-rate-block')), findsNothing);
    final rateField = find.byKey(const Key('finance-audit-exchange-rate'));
    expect(tester.widget<TextField>(rateField).controller!.text, '7');
    expect(tester.widget<TextField>(rateField).readOnly, isFalse);
    final approve = find.byKey(const Key('finance-shipment-audit-approve'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finance-shipment-audit-confirm')));
    await tester.pumpAndSettle();
    final body =
        api.postBodies['/sales/shipments/shipment-master-rate/finance-audit']
            as Map<String, dynamic>;
    expect(body['exchangeRate'], '7');
  });

  testWidgets('base currency locks the recognition rate to one', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-base-rate',
        'financeReviewPending': true,
        'salesConfirmed': true,
        'status': 0,
        'financeAudit': 0,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[],
      },
      claimSucceeds: true,
      financeAuditInfo: const {
        'shipmentId': 'shipment-base-rate',
        'reviewRevision': 0,
        'contentHash': 'base-rate-content',
        'financeAudit': 0,
        'clientName': '人民币客户',
        'currencyName': '人民币',
        'financeRate': '0.000000',
        'financeRateReady': true,
        'baseCurrency': true,
        'shipmentExchangeRate': '',
        'suggestedExchangeRate': '1',
      },
    );
    expect(find.text('1(本位币)'), findsOneWidget);
    expect(find.byKey(const Key('finance-audit-rate-block')), findsNothing);
    final rateField = find.byKey(const Key('finance-audit-exchange-rate'));
    expect(tester.widget<TextField>(rateField).controller!.text, '1');
    expect(tester.widget<TextField>(rateField).readOnly, isTrue);
    final approve = find.byKey(const Key('finance-shipment-audit-approve'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('finance-shipment-audit-confirm')));
    await tester.pumpAndSettle();
    final body =
        api.postBodies['/sales/shipments/shipment-base-rate/finance-audit']
            as Map<String, dynamic>;
    expect(body['exchangeRate'], '1');
  });

  testWidgets('released shipment shows the frozen recognition rate read-only', (
    tester,
  ) async {
    await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-frozen-rate',
        'billNo': 'XS-FROZEN',
        'salesConfirmed': true,
        'status': 0,
        'financeAudit': 1,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[],
      },
      financeAuditInfo: const {
        'shipmentId': 'shipment-frozen-rate',
        'reviewRevision': 1,
        'contentHash': 'frozen-content',
        'financeAudit': 1,
        'clientName': '美金客户',
        'currencyName': '美金',
        'financeRate': '8.000000',
        'financeRateReady': true,
        'baseCurrency': false,
        'shipmentExchangeRate': '7.25',
        'suggestedExchangeRate': '7.25',
      },
    );
    expect(find.byKey(const Key('finance-audit-exchange-rate')), findsNothing);
    final frozen = find.byKey(const Key('finance-audit-rate-frozen'));
    expect(frozen, findsOneWidget);
    expect(tester.widget<Text>(frozen).data, contains('已冻结记账汇率 7.25'));
  });

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

  // permissions-15：按钮只认服务端下发的 allowedActions，本地权限集合不再参与判断。
  testWidgets('decision buttons follow server allowedActions only', (
    tester,
  ) async {
    const detail = {
      'id': 'shipment-allowed-actions',
      'billNo': 'XS-20260923-001',
      'financeReviewPending': true,
      'salesConfirmed': true,
      'status': 0,
      'financeAudit': 0,
      'warehouseWorkStatus': 'PENDING_PICK',
      'items': <Map<String, dynamic>>[
        {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 10},
      ],
    };
    // 本地只持查看码，但服务端判定可放行(例如经页面委派刚拿到放行权)：按服务端显示。
    final api = await _pumpReviewPage(
      tester,
      detail: detail,
      claimSucceeds: true,
      permissions: const {Perm.salesShipmentFinanceView},
      financeAuditInfo: const {
        'shipmentId': 'shipment-allowed-actions',
        'reviewRevision': 1,
        'contentHash': 'hash-1',
        'financeAudit': 0,
        'clientName': '测试客户',
        'allowedActions': ['APPROVE'],
      },
    );
    expect(
      find.byKey(const Key('finance-shipment-audit-approve')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('finance-shipment-audit-reject')),
      findsNothing,
    );
    expect(api.postPaths.any((path) => path.endsWith('/claim')), isTrue);
  });

  testWidgets('no allowed action: no decision buttons and no claim', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-no-actions',
        'billNo': 'XS-20260923-002',
        'financeReviewPending': true,
        'salesConfirmed': true,
        'status': 0,
        'financeAudit': 0,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[
          {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 10},
        ],
      },
      claimSucceeds: true,
      financeAuditInfo: const {
        'shipmentId': 'shipment-no-actions',
        'reviewRevision': 1,
        'contentHash': 'hash-1',
        'financeAudit': 0,
        'clientName': '测试客户',
        // 本地码齐全，但服务端判定这张单不归本人办理(对象范围之外)。
        'allowedActions': <String>[],
      },
    );
    expect(
      find.byKey(const Key('finance-shipment-audit-approve')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('finance-shipment-audit-reject')),
      findsNothing,
    );
    expect(api.postPaths.any((path) => path.endsWith('/claim')), isFalse);
  });

  // V578：被退回的单据在财务侧有显式出口——「撤回退回」恢复待审，
  // 退回原因与出货内容无关（如客户结账方式待核对）时无需销售改单来回。
  testWidgets('rejected shipment offers reject reversal back to pending', (
    tester,
  ) async {
    final api = await _pumpReviewPage(
      tester,
      detail: const {
        'id': 'shipment-reject-reverse',
        'billNo': 'XS-20260914-009',
        'salesConfirmed': true,
        'status': 0,
        'financeAudit': 0,
        'financeRejected': true,
        'financeRejectionReason': '客户结账方式待核对',
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[
          {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 10},
        ],
      },
      financeAuditInfo: const {
        'shipmentId': 'shipment-reject-reverse',
        'reviewRevision': 1,
        'contentHash': 'hash-1',
        'financeAudit': 0,
        'clientName': '测试客户',
      },
    );
    expect(find.textContaining('已退回销售'), findsOneWidget);
    expect(find.textContaining('客户结账方式待核对'), findsWidgets);
    final reverse = find.byKey(
      const Key('finance-shipment-audit-reject-reverse-btn'),
    );
    expect(reverse, findsOneWidget);
    await tester.tap(reverse);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('finance-shipment-audit-reject-reverse')),
    );
    await tester.pumpAndSettle();
    expect(
      api.postPaths,
      contains(
        '/sales/shipments/shipment-reject-reverse/finance-reject-reverse',
      ),
    );
  });
}

Future<_ReviewApi> _pumpReviewPage(
  WidgetTester tester, {
  required Map<String, dynamic> detail,
  Map<String, dynamic>? financeAuditInfo,
  bool claimSucceeds = false,
  Set<String> permissions = const {
    Perm.salesShipmentFinanceView,
    Perm.salesShipmentFinanceApprove,
    Perm.salesShipmentFinanceReject,
    Perm.salesShipmentFinanceReverse,
  },
  Size surfaceSize = const Size(1500, 1100),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _ReviewApi(
    detail,
    financeAuditInfo: financeAuditInfo,
    claimSucceeds: claimSucceeds,
    grants: permissions,
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
  _ReviewApi(
    this.detail, {
    this.financeAuditInfo,
    this.claimSucceeds = false,
    this.grants = const {},
  }) : super(Dio());

  /// 本账号持有的码：只用来模拟服务端算 allowedActions，页面自己不再读它决定按钮。
  final Set<String> grants;

  /// 模拟服务端按动作码 + 单据状态算出的可执行动作
  /// (真实口径见 SalesShipmentService.financeAllowedActions)。
  List<String> _serverAllowedActions() {
    if (detail['status'] != 0 ||
        detail['warehouseWorkStatus'] != 'PENDING_PICK') {
      return const [];
    }
    final released = detail['financeAudit'] == 1;
    final rejected = detail['financeRejected'] == true;
    final awaiting = !released && !rejected;
    return [
      if (awaiting && grants.contains(Perm.salesShipmentFinanceApprove))
        'APPROVE',
      if (awaiting && grants.contains(Perm.salesShipmentFinanceReject))
        'REJECT',
      if ((released || rejected) &&
          grants.contains(Perm.salesShipmentFinanceReverse))
        'REVERSE',
    ];
  }

  bool claimSucceeds;
  bool failHeartbeat = false;

  final Map<String, dynamic> detail;
  final Map<String, dynamic>? financeAuditInfo;
  final List<String> getPaths = [];
  final List<String> postPaths = [];
  final Map<String, Object?> postBodies = {};

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
        'allowedActions': _serverAllowedActions(),
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
    postBodies[path] = body;
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
    if (path.endsWith('/finance-reject-reverse')) {
      return <String, dynamic>{
        ...?financeAuditInfo,
        'financeAudit': 0,
        'financeRejected': false,
      };
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
