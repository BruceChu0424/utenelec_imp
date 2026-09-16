import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  for (final (state, expected) in <(Map<String, dynamic>, bool)>[
    ({}, false),
    ({'salesConfirmed': true}, true),
    ({'financeRejected': true}, true),
    ({'financeAudit': 1}, true),
    ({'status': 1}, true),
    ({'shipmentKind': 'DIRECT_CUSTOMER', 'salesConfirmed': true}, true),
    ({'salesConfirmed': true, 'priceMasked': true}, false),
  ]) {
    testWidgets(
      'finance-only shipment attachment visibility follows submitted state $state',
      (tester) async {
        await _pumpDetail(
          tester,
          type: SalesDocType.shipment,
          detail: {
            'id': 'finance-file-shipment',
            'status': 0,
            'items': <Map<String, dynamic>>[],
            ...state,
          },
          permissions: const {Perm.financeShipmentAudit},
        );
        final section = tester.widget<BusinessAttachmentSection>(
          find.byType(BusinessAttachmentSection),
        );
        expect(section.ownerType, 'SALES_SHIPMENT');
        expect(section.canView, expected);
        expect(section.canManage, isFalse);
        expect(find.text('添加文件'), findsNothing);
      },
    );
  }

  testWidgets('new shipment shows warehouse actions and hides legacy approve', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-1',
        'status': 0,
        'writable': true,
        'financeAudit': 1,
        'warehouseWorkStatus': 'PENDING_PICK',
        'canManageWarehouseWork': true,
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.salesShipmentWarehouseWork},
    );

    // V582：财务放行后仓库只剩「确认出库」一个动作，没有拣货/异常分支。
    expect(find.text('确认出库'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('warehouse-work-confirmShipment')),
      findsOneWidget,
    );
    expect(find.text('登记异常'), findsNothing);
    expect(find.text('审核'), findsNothing);
  });

  testWidgets('unaudited shipment keeps warehouse actions locked', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-wait-finance',
        'status': 0,
        'writable': true,
        'financeAudit': 0,
        'warehouseWorkStatus': 'PENDING_PICK',
        'canManageWarehouseWork': true,
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.salesShipmentWarehouseWork},
    );

    expect(find.text('确认出库'), findsNothing);
    expect(find.textContaining('等待财务审核放行'), findsOneWidget);
  });

  testWidgets('legacy shipment fails closed without either approval path', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-legacy',
        'status': 0,
        'writable': true,
        'warehouseWorkStatus': 'LEGACY_PENDING',
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.salesShipmentApprove},
    );

    expect(find.text('审核'), findsNothing);
    expect(find.byKey(const ValueKey('finance-audit')), findsNothing);
    expect(find.byKey(const ValueKey('legacy-sales-approve')), findsNothing);
    expect(find.text('确认出库'), findsNothing);
    expect(find.textContaining('历史直接审核流程已停用'), findsOneWidget);
  });

  testWidgets('order approval describes order activation without AR wording', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.order,
      detail: const {
        'id': 'order-draft',
        'status': 0,
        'writable': true,
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.salesOrderApprove},
    );

    await tester.tap(find.text('审核'));
    await tester.pump();

    // V300：审核弹窗明示后续流转——生效+预留，随后自动转发财务审核，财务确认后才排产。
    expect(
      find.text('审核通过后订单将生效并形成库存预留，随后自动转发财务审核；财务确认通过后计划部才可见并排产。确认审核？'),
      findsOneWidget,
    );
    expect(find.textContaining('应收'), findsNothing);
    expect(find.textContaining('财务汇率'), findsNothing);
  });

  testWidgets('finance actions disappear once the warehouse shipped it', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-shipped',
        'status': 1,
        'financeAudit': 1,
        'warehouseWorkStatus': 'SHIPPED',
        'handedOverAt': '2026-09-14T10:00:00+08:00',
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.financeShipmentAudit},
    );

    expect(find.byKey(const ValueKey('finance-audit')), findsNothing);
    expect(find.byKey(const ValueKey('finance-audit-reverse')), findsNothing);
    expect(find.text('确认出库'), findsNothing);
  });

  testWidgets('finance-audited pending-pick draft allows controlled editing', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-finance-audited',
        'status': 0,
        'writable': true,
        'financeAudit': 1,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.financeShipmentAudit, Perm.salesShipmentEdit},
    );

    expect(find.byKey(const ValueKey('sales-doc-edit')), findsOneWidget);
    expect(find.textContaining('如需修改出货内容，请先财务反审'), findsNothing);
    // 2026-09-12 拆分：财务反审入口移入财务专用审核页，本页只展示状态横幅。
    expect(find.byKey(const ValueKey('finance-audit-reverse')), findsNothing);
    expect(find.textContaining('财务已放行'), findsOneWidget);
  });

  testWidgets(
    'shipment waiting for finance audit shows status strip, not audit buttons',
    (tester) async {
      // 2026-09-12 拆分：本页只显示「正在等待财务审核」横幅 + 销售/仓库操作；
      // 财务认领/放行/反审全部在 /finance/sales-shipment-audits/:id 专页办理。
      await _pumpDetail(
        tester,
        type: SalesDocType.shipment,
        detail: const {
          'id': 'shipment-waiting-strip',
          'financeReviewPending': true,
          'salesConfirmed': true,
          'status': 0,
          'financeAudit': 0,
          'warehouseWorkStatus': 'PENDING_PICK',
          'writable': true,
          'items': <Map<String, dynamic>>[
            {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 100},
          ],
        },
        permissions: const {
          Perm.financeShipmentAudit,
          Perm.salesShipmentEdit,
          Perm.salesShipmentDelete,
        },
      );

      expect(
        find.byKey(const Key('shipment-finance-status-strip')),
        findsOneWidget,
      );
      expect(find.textContaining('正在等待财务审核'), findsOneWidget);
      expect(find.byKey(const ValueKey('finance-audit')), findsNothing);
      expect(find.byKey(const ValueKey('finance-audit-reverse')), findsNothing);
      // 销售操作仍在（编辑）；出货草稿的删除入口按用户口径显示为「取消」。
      expect(find.byKey(const ValueKey('sales-doc-edit')), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('删除'), findsNothing);
    },
  );

  testWidgets('shipped state hides direct reverse without handover time', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-shipped',
        'status': 1,
        'writable': true,
        'warehouseWorkStatus': 'SHIPPED',
        'items': <Map<String, dynamic>>[],
      },
    );

    expect(find.text('红冲'), findsNothing);
    expect(find.textContaining('仅价款有误须财务调整，不能虚做退货'), findsOneWidget);
  });

  testWidgets(
    'planned order hides guaranteed-failure cancel and gives remedy',
    (tester) async {
      await _pumpDetail(
        tester,
        type: SalesDocType.order,
        detail: const {
          'id': 'order-planned',
          'status': 1,
          'writable': true,
          'shipmentPolicy': 'REQUIRE_COMPLETE',
          'items': [
            {'id': 'line-1', 'plannedQty': 10, 'chainStatus': 4},
          ],
        },
      );

      expect(find.text('取消订单'), findsNothing);
      expect(find.textContaining('已有排产、在产或完工关联'), findsOneWidget);
    },
  );

  testWidgets('approved finance-rejected order exposes modify action', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.order,
      detail: const {
        'id': 'order-finance-rejected',
        'billNo': 'SO-REJECTED',
        'status': 1,
        'writable': true,
        'financeConfirmed': false,
        'financeRejected': true,
        'financeRejectedReason': '结账方式错误',
        'shipmentPolicy': 'ALLOW_PARTIAL',
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.salesOrderEdit},
    );

    expect(find.textContaining('结账方式错误'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sales-order-finance-rejected-edit')),
      findsOneWidget,
    );
    expect(find.text('修改订单'), findsOneWidget);
  });

  testWidgets(
    '"登记客户同意分批" button removed: partial shipment no longer needs customer consent evidence',
    (tester) async {
      // 问题 #16/#18：发运策略选了 CUSTOMER_CONFIRM 不再要求先登记客户同意依据才能
      // 部分发货——那步登记 UI 从没做完整（没有可用的录入入口），订单实际上永远卡住；
      // 现在直接按员工选的策略生效，详情页也不再展示这颗按钮。
      await _pumpDetail(
        tester,
        type: SalesDocType.order,
        detail: const {
          'id': 'order-confirm',
          'status': 1,
          'writable': false,
          'shipmentPolicy': 'CUSTOMER_CONFIRM',
          'items': <Map<String, dynamic>>[],
        },
        permissions: const {Perm.salesOrderConfirmPartialShipment},
      );

      expect(find.text('登记客户同意分批'), findsNothing);
      expect(find.text('红冲'), findsNothing);
    },
  );

  testWidgets('order detail hides exchange rate and policy explanation', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.order,
      detail: const {
        'id': 'order-rate-hidden',
        'status': 0,
        'writable': true,
        'currencyId': 'currency-usd',
        'exchangeRate': 7.2,
        'totalOriginal': 160,
        'totalLocal': 1152,
        'deposit': 999.99,
        'shipmentPolicy': 'ALLOW_PARTIAL',
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'order-line-1',
            'qty': 2,
            'price': 100,
            'discount': 0.8,
            'amountOriginal': 160,
            'amountLocal': 1152,
          },
        ],
      },
    );

    expect(find.text('币种'), findsOneWidget);
    expect(find.text('汇率'), findsNothing);
    expect(find.text('订单金额(美元)'), findsOneWidget);
    expect(find.text('160.00'), findsWidgets);
    expect(find.text('200.00'), findsNothing);
    expect(find.text('合计(本币)'), findsNothing);
    expect(find.text('1152.00'), findsNothing);
    expect(find.text('发运策略'), findsOneWidget);
    expect(find.text('策略说明'), findsNothing);
    expect(find.textContaining('允许按可用库存分批发运'), findsNothing);
    expect(find.text('订金'), findsNothing);
    expect(find.text('财务预收累计'), findsNothing);
    expect(
      find.byKey(const ValueKey('sales-order-money-summary')),
      findsNothing,
    );
  });

  testWidgets('non-order currency detail keeps exchange rate', (tester) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.otherShipment,
      detail: const {
        'id': 'other-shipment-rate',
        'status': 0,
        'writable': true,
        'currencyId': 'currency-usd',
        'exchangeRate': 7.2,
        'items': <Map<String, dynamic>>[],
      },
    );

    expect(find.text('币种'), findsOneWidget);
    expect(find.text('汇率'), findsOneWidget);
  });
}

Future<_DetailApi> _pumpDetail(
  WidgetTester tester, {
  required SalesDocType type,
  required Map<String, dynamic> detail,
  Set<String> permissions = const {},
  Map<String, dynamic>? financeAuditInfo,
  bool claimSucceeds = false,
  Size surfaceSize = const Size(1500, 1100),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _DetailApi(
    detail,
    financeAuditInfo: financeAuditInfo,
    claimSucceeds: claimSucceeds,
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
      child: MaterialApp(
        home: SalesDocDetailPage(docType: type, id: detail['id'] as String),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

class _DetailApi extends ApiClient {
  _DetailApi(this.detail, {this.financeAuditInfo, this.claimSucceeds = false})
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
      if (!claimSucceeds || path.endsWith('/heartbeat') && failHeartbeat) {
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
    if (!path.endsWith('/finance-audit')) {
      throw StateError('unsupported test POST: $path');
    }
    return <String, dynamic>{...?financeAuditInfo, 'financeAudit': 1};
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
