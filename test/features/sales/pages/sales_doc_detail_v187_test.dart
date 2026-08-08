import 'package:dio/dio.dart';
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
    expect(find.text('请填写原因或处理依据'), findsOneWidget);
  });

  testWidgets('legacy shipment keeps the historical approve action', (
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
    );

    expect(find.text('审核'), findsOneWidget);
    expect(find.text('开始拣货'), findsNothing);
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

  testWidgets('finance-audited pending-pick draft hides the edit entry', (
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
      permissions: const {Perm.financeShipmentAudit},
    );

    expect(find.byKey(const ValueKey('sales-doc-edit')), findsNothing);
    expect(find.textContaining('如需修改出货内容，请先财务反审'), findsOneWidget);
    expect(find.byKey(const ValueKey('finance-audit-reverse')), findsOneWidget);
  });

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
    expect(find.textContaining('已出库/历史交接事实未知，须走销售退货或受控纠错'), findsOneWidget);
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
        'shipmentPolicy': 'ALLOW_PARTIAL',
        'items': <Map<String, dynamic>>[],
      },
    );

    expect(find.text('币种'), findsOneWidget);
    expect(find.text('汇率'), findsNothing);
    expect(find.text('发运策略'), findsOneWidget);
    expect(find.text('策略说明'), findsNothing);
    expect(find.textContaining('允许按可用库存分批发运'), findsNothing);
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

Future<void> _pumpDetail(
  WidgetTester tester, {
  required SalesDocType type,
  required Map<String, dynamic> detail,
  Set<String> permissions = const {},
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = _DetailApi(detail);
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
}

class _DetailApi extends ApiClient {
  _DetailApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return const [];
  }
}
