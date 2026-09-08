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

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

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

    expect(find.text('开始拣货'), findsOneWidget);
    expect(find.text('登记异常'), findsOneWidget);
    expect(find.text('审核'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('warehouse-work-reportException')),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '登记异常'));
    await tester.pump();
    // 2026-09-04 ⓘ字段说明全站化：必填原因校验文案进输入框 ⓘ Tooltip
    //（UtenInputDecoration 不再占底部错误槽），断言用 Tooltip.message 谓词。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && widget.message?.contains('请填写原因或处理依据') == true,
      ),
      findsOneWidget,
    );
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

    expect(find.text('开始拣货'), findsNothing);
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
    expect(find.text('开始拣货'), findsNothing);
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

  testWidgets('finance actions disappear after picking has started', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-picking',
        'status': 0,
        'financeAudit': 0,
        'warehouseWorkStatus': 'PICKING',
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.financeShipmentAudit},
    );

    expect(find.byKey(const ValueKey('finance-audit')), findsNothing);
    expect(find.byKey(const ValueKey('finance-audit-reverse')), findsNothing);
    expect(find.textContaining('仓库作业已开始，不能补做或撤销财务审核'), findsOneWidget);
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
    expect(find.byKey(const ValueKey('finance-audit-reverse')), findsOneWidget);
  });

  testWidgets('finance audit previews customer facts before posting approval', (
    tester,
  ) async {
    final api = await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      detail: const {
        'id': 'shipment-finance-preview',
        'financeReviewPending': true,
        'status': 0,
        'financeAudit': 0,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[
          {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 100},
        ],
      },
      permissions: const {Perm.financeShipmentAudit},
      claimSucceeds: true,
      surfaceSize: const Size(375, 812),
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

    await tester.tap(find.byKey(const ValueKey('finance-audit')));
    await tester.pumpAndSettle();

    expect(
      api.getPaths,
      contains('/sales/shipments/shipment-finance-preview/finance-audit-info'),
    );
    expect(find.byKey(const Key('finance-audit-info-dialog')), findsOneWidget);
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
    expect(api.postPaths.any((path) => path.endsWith('/claim')), isTrue);

    final confirm = find.byKey(const Key('finance-audit-info-confirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(
      api.postPaths,
      contains('/sales/shipments/shipment-finance-preview/finance-audit'),
    );
  });

  testWidgets(
    'shipment finance claim network failure blocks review and can retry',
    (tester) async {
      final api = await _pumpDetail(
        tester,
        type: SalesDocType.shipment,
        detail: const {
          'id': 'shipment-retry',
          'status': 0,
          'financeAudit': 0,
          'financeReviewPending': true,
          'warehouseWorkStatus': 'PENDING_PICK',
          'items': <Map<String, dynamic>>[],
        },
        permissions: const {Perm.financeShipmentAudit},
        financeAuditInfo: const {
          'shipmentId': 'shipment-retry',
          'reviewRevision': 1,
          'contentHash': 'retry-content',
          'salesPaymentType': 'CASH',
        },
      );
      await tester.tap(find.byKey(const ValueKey('finance-audit')));
      await tester.pumpAndSettle();
      expect(
        api.getPaths.where((path) => path.endsWith('/finance-audit-info')),
        isEmpty,
      );
      expect(find.byKey(const Key('finance-audit-info-dialog')), findsNothing);
      expect(
        api.postPaths.where((path) => path.endsWith('/finance-audit')),
        isEmpty,
      );
      api.claimSucceeds = true;
      await tester.tap(find.byKey(const ValueKey('finance-audit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('finance-audit-info-dialog')),
        findsOneWidget,
      );
      final button = find.byKey(const Key('finance-audit-info-confirm'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        api.postPaths.where((path) => path.endsWith('/finance-audit')),
        hasLength(1),
      );
    },
  );

  testWidgets('shipment finance lost lease pauses decision before posting', (
    tester,
  ) async {
    final api = await _pumpDetail(
      tester,
      type: SalesDocType.shipment,
      claimSucceeds: true,
      detail: const {
        'id': 'shipment-lost',
        'status': 0,
        'financeAudit': 0,
        'financeReviewPending': true,
        'warehouseWorkStatus': 'PENDING_PICK',
        'items': <Map<String, dynamic>>[],
      },
      permissions: const {Perm.financeShipmentAudit},
      financeAuditInfo: const {
        'shipmentId': 'shipment-lost',
        'reviewRevision': 1,
        'contentHash': 'lost-content',
        'salesPaymentType': 'CASH',
      },
    );
    await tester.tap(find.byKey(const ValueKey('finance-audit')));
    await tester.pumpAndSettle();
    api.failHeartbeat = true;
    final button = find.byKey(const Key('finance-audit-info-confirm'));
    await tester.ensureVisible(button);
    await tester.tap(button);
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
      final api = await _pumpDetail(
        tester,
        type: SalesDocType.shipment,
        detail: const {
          'id': 'shipment-unclassified',
          'financeReviewPending': true,
          'status': 0,
          'financeAudit': 0,
          'warehouseWorkStatus': 'PENDING_PICK',
          'items': <Map<String, dynamic>>[
            {'id': 'line-1', 'goodsId': 'goods-1', 'qty': 1, 'price': 100},
          ],
        },
        permissions: const {Perm.financeShipmentAudit, Perm.clientView},
        claimSucceeds: true,
        surfaceSize: const Size(375, 812),
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

      await tester.tap(find.byKey(const ValueKey('finance-audit')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('finance-audit-classification-block')),
        findsOneWidget,
      );
      expect(find.textContaining('联系有客户资料维护权限的人员'), findsOneWidget);
      expect(
        find.byKey(const Key('finance-audit-open-client-master')),
        findsNothing,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byKey(const Key('finance-audit-info-confirm')),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        api.postPaths.where((path) => path.endsWith('/finance-audit')),
        isEmpty,
      );
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
