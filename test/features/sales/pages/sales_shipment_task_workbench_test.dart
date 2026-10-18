import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_shipment_audit_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_task_center_record.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../../helpers/badge_summary_fixture.dart';

late SharedPreferences _preferences;
final _permissionStateProvider = StateProvider<Set<String>>((ref) => {});

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets('finance task page defaults to pending and uses desktop table', (
    tester,
  ) async {
    final api = _ShipmentTaskApi();
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.salesShipmentFinanceView,
      api: api,
      size: const Size(1440, 900),
    );

    expect(
      find.byKey(const Key('finance-shipment-audit-table')),
      findsOneWidget,
    );
    expect(api.shipmentQueries.single['financeAudit'], 0);
    expect(api.shipmentQueries.single['status'], kSalesStatusDraft);
    expect(
      api.shipmentQueries.single['warehouseWorkStatus'],
      SalesWarehouseWorkStatus.pendingPick,
    );
    expect(find.text('财务审核'), findsWidgets);
    expect(find.text('仓库作业'), findsOneWidget);
    // ADR-128：出货金额按本单币种写成「币种 金额」。
    expect(find.text('100.00 美金'), findsOneWidget);
    final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
      find.byKey(const Key('finance-shipment-audit-table')),
    );
    expect(table.items.single.shipmentWorkflow.financeReviewPending, isTrue);
    expect(table.selectable, isFalse);
    expect(table.batchActionsBuilder, isNull);
    expect(
      find.byKey(const Key('finance-shipment-batch-approve')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('finance-shipment-batch-reject')),
      findsNothing,
    );
  });

  for (final size in [const Size(1440, 900), const Size(375, 812)]) {
    for (final (label, actionPermissions, approve, reject) in [
      ('approve only', {Perm.salesShipmentFinanceApprove}, true, false),
      ('reject only', {Perm.salesShipmentFinanceReject}, false, true),
      (
        'both decisions',
        {Perm.salesShipmentFinanceApprove, Perm.salesShipmentFinanceReject},
        true,
        true,
      ),
    ]) {
      testWidgets('finance batch actions match $label at $size', (
        tester,
      ) async {
        await _pump(
          tester,
          page: const FinanceSalesShipmentAuditPage(),
          permission: Perm.salesShipmentFinanceView,
          extraPermissions: actionPermissions,
          api: _ShipmentTaskApi(),
          size: size,
        );
        final table = tester.widget<MasterDataTableView<SalesDocListItem>>(
          find.byKey(const Key('finance-shipment-audit-table')),
        );
        expect(table.selectable, isTrue);
        table.onSelectedIdsChanged?.call({'shipment-1'});
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('finance-shipment-batch-approve')),
          approve ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('finance-shipment-batch-reject')),
          reject ? findsOneWidget : findsNothing,
        );
      });
    }
  }

  testWidgets(
    'revoked action authority hides selection and blocks a retained approval callback',
    (tester) async {
      final api = _ShipmentTaskApi();
      await _pump(
        tester,
        page: const FinanceSalesShipmentAuditPage(),
        permission: Perm.salesShipmentFinanceView,
        extraPermissions: {Perm.salesShipmentFinanceApprove},
        api: api,
        size: const Size(1440, 900),
      );
      final tableFinder = find.byKey(const Key('finance-shipment-audit-table'));
      tester
          .widget<MasterDataTableView<SalesDocListItem>>(tableFinder)
          .onSelectedIdsChanged
          ?.call({'shipment-1'});
      await tester.pumpAndSettle();
      final previousApproval = tester
          .widget<UtenButton>(
            find.byKey(const Key('finance-shipment-batch-approve')),
          )
          .onPressed!;
      final container = ProviderScope.containerOf(tester.element(tableFinder));
      container.read(_permissionStateProvider.notifier).state = {
        Perm.salesShipmentFinanceView,
      };
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MasterDataTableView<SalesDocListItem>>(tableFinder)
            .selectable,
        isFalse,
      );
      expect(
        find.byKey(const Key('finance-shipment-batch-approve')),
        findsNothing,
      );
      previousApproval();
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'warehouse task page stays usable at 375px and filters work status',
    (tester) async {
      // 2026-10-17 24abc2aed 起独立页并入仓库任务中心（出库 · 销售出库）：
      // 列表改走 /warehouse/task-center/outbound 投影（不再查
      // /warehouse/sales-outbound），作业阶段由状态表头查询（旧「待出库/
      // 已出库」分段退役）；深链 initialSection: SALES 挂载即选中并加载。
      final api = _TaskCenterApi();
      await tester.binding.setSurfaceSize(const Size(375, 812));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localServerReachableProvider.overrideWith(
              (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
            ),
            sharedPreferencesProvider.overrideWithValue(_preferences),
            apiClientProvider.overrideWithValue(api),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseSalesOutboundView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            // 分段红数随徽章汇总一次带回(ADR-108/184)：销售出库待出库红 1。
            fixedBadgeSummaryOverride(
              badgeSummaryFixture(
                facts: {BadgeFact.warehouseSalesOutboundPendingPick: 1},
              ),
            ),
          ],
          child: const MaterialApp(home: WarehouseSalesOutboundPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 375px 下仍可用：销售出库小类自动选中，表格已加载出库任务行。
      expect(find.text('SO-OUT-001'), findsOneWidget);
      expect(api.queries.first['source'], 'SALES');
      expect(
        api.queries.first.containsKey('status'),
        isFalse,
        reason: '挂载首查不带作业状态（状态由表头筛选下发）',
      );

      // 作业阶段筛选（状态表头）：待出库 → 已出库，逐次下发服务端。
      MasterDataTableView<WarehouseTaskCenterRecord> table() => tester.widget(
        find.byKey(const ValueKey('warehouse-task-records-outbound')),
      );
      table().onFilterChanged('status', SalesWarehouseWorkStatus.pendingPick);
      await tester.pumpAndSettle();
      expect(api.queries.last['status'], SalesWarehouseWorkStatus.pendingPick);
      expect(api.queries.last['source'], 'SALES');

      table().onFilterChanged('status', SalesWarehouseWorkStatus.shipped);
      await tester.pumpAndSettle();
      expect(api.queries.last['status'], SalesWarehouseWorkStatus.shipped);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('task page exposes recoverable initial error state', (
    tester,
  ) async {
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.salesShipmentFinanceView,
      api: _ShipmentTaskApi(fail: true),
      size: const Size(375, 812),
    );

    expect(find.text('出货财务审核任务加载失败'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
  });

  testWidgets('missing exact permission shows denial without requesting API', (
    tester,
  ) async {
    final api = _ShipmentTaskApi();
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.salesShipmentView,
      api: api,
      size: const Size(375, 812),
    );

    expect(find.text('无权查看出货财务审核'), findsOneWidget);
    expect(api.shipmentQueries, isEmpty);
  });

  testWidgets('empty finance queue explains how a new task appears', (
    tester,
  ) async {
    await _pump(
      tester,
      page: const FinanceSalesShipmentAuditPage(),
      permission: Perm.salesShipmentFinanceView,
      api: _ShipmentTaskApi(empty: true),
      size: const Size(375, 812),
    );

    // 2026-09-12 起财务模式大小屏统一响应式表格（多选/批量/双击进审核详情）。
    expect(
      find.byKey(const Key('finance-shipment-audit-table')),
      findsOneWidget,
    );
    expect(find.text('暂无待财务审核的出货单'), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget page,
  required String permission,
  Set<String> extraPermissions = const {},
  required _ShipmentTaskApi api,
  required Size size,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiClientProvider.overrideWithValue(api),
        _permissionStateProvider.overrideWith(
          (ref) => {permission, ...extraPermissions},
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissionStateProvider),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 出库任务中心投影假 API（/warehouse/task-center/outbound）：一条销售出库
/// 待出库行 + 待出库/已出库两个作业状态 facet（状态表头筛选项与服务端契约一致）。
class _TaskCenterApi extends ApiClient {
  _TaskCenterApi() : super(Dio());

  final List<Map<String, dynamic>> queries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/warehouse/task-center/outbound') {
      return const <String, dynamic>{};
    }
    queries.add(Map<String, dynamic>.from(query ?? const {}));
    return <String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'rowKey': 'SALES:SHIPMENT:shipment-1',
          'id': 'shipment-1',
          'sourceType': 'SALES',
          'recordType': 'SHIPMENT',
          'status': SalesWarehouseWorkStatus.pendingPick,
          'statusLabel': '待出库',
          'billNo': 'SO-OUT-001',
          'sourceDocNo': 'XS-001',
          'businessDate': '2026-08-31',
          'partyName': '客户甲',
          'warehouseName': '一号仓',
          'responsibleName': '仓管甲',
          'canHandle': false,
        },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
      'facets': {
        'status': <Map<String, dynamic>>[
          {
            'value': SalesWarehouseWorkStatus.pendingPick,
            'label': '待出库',
            'count': 1,
          },
          {
            'value': SalesWarehouseWorkStatus.shipped,
            'label': '已出库',
            'count': 0,
          },
        ],
        'billNo': <Map<String, dynamic>>[],
      },
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];
}

class _ShipmentTaskApi extends ApiClient {
  _ShipmentTaskApi({this.fail = false, this.empty = false}) : super(Dio());

  final bool fail;
  final bool empty;
  final List<Map<String, dynamic>> shipmentQueries = [];
  final List<String> writes = [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(path);
    throw StateError('Unexpected write');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/sales/shipments') return const <String, dynamic>{};
    shipmentQueries.add(Map<String, dynamic>.from(query ?? const {}));
    if (fail) throw StateError('offline');
    return <String, dynamic>{
      'items': empty
          ? <Map<String, dynamic>>[]
          : <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'shipment-1',
                'billNo': 'XS202608310001',
                'billDate': '2026-08-31',
                'clientId': 'client-1',
                'warehouseId': 'warehouse-1',
                'currencyId': 'currency-1',
                'totalOriginal': 100,
                'status': 0,
                'financeAudit': 0,
                'financeReviewPending': true,
                'warehouseWorkStatus': 'PENDING_PICK',
              },
            ],
      'page': 1,
      'size': 20,
      'total': empty ? 0 : 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/clients/dict')) {
      return const [
        {'id': 'client-1', 'code': 'C001', 'name': '测试客户'},
      ];
    }
    if (path.endsWith('/currencies/dict')) {
      return const [
        {'id': 'currency-1', 'code': '002', 'name': '美金'},
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}
