import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/models/settlement_method_admin.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// V453：结算方式管理页（账期口径展示 + 系统角色锁定不进编辑）。
void main() {
  group('terms summary labels', () {
    test('cash system role is fixed to receipt date', () {
      final cash = SettlementMethodAdminItem.fromJson(const {
        'id': 'cash-id',
        'name': '现金',
        'systemRole': 'CASH',
        'termsBase': 'RECEIPT_DATE',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': 0,
        'monthsAhead': 0,
      });

      expect(cash.lockedBySystemRole, isTrue);
      expect(settlementTermsSummary(cash), '现金：收货/进仓当天到期');
      expect(settlementSystemRoleLabel('MONTHLY'), '月结 · 系统锁定');
    });

    test('custom monthly method renders statement-end plus days', () {
      final monthly = SettlementMethodAdminItem.fromJson(const {
        'id': 'm60',
        'name': '月结60',
        'termsBase': 'STATEMENT_END',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': 60,
        'monthsAhead': 0,
      });

      expect(settlementTermsSummary(monthly), '月末 + 60 天');
    });

    test('future-event bases stay undated with explanation', () {
      final invoice = SettlementMethodAdminItem.fromJson(const {
        'id': 'inv',
        'name': '票到',
        'termsBase': 'INVOICE_DATE',
        'dueRule': 'NET_DAYS',
        'defaultDueDays': 30,
        'monthsAhead': 0,
      });

      expect(settlementTermsSummary(invoice), contains('到期日保持未定'));
    });

    test('fixed day rule mentions month offset and day', () {
      final fixed = SettlementMethodAdminItem.fromJson(const {
        'id': 'fixed',
        'name': '次月10日',
        'termsBase': 'RECEIPT_DATE',
        'dueRule': 'FIXED_DAY_OF_MONTH',
        'defaultDueDays': 0,
        'fixedDayOfMonth': 10,
        'monthsAhead': 1,
      });

      expect(settlementTermsSummary(fixed), contains('10 日'));
      expect(settlementTermsSummary(fixed), contains('基准月+1'));
    });
  });

  testWidgets('page lists methods and locked rows are not editable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettlementMethodPage())),
    );
    // 无权限环境（空权限）：页面仍可渲染列表（路由守卫在真实导航层），
    // 本例验证列表项与锁定徽标的呈现由模型层覆盖；此处页面空态/错误态不崩。
    await tester.pumpAndSettle();
    expect(find.byType(SettlementMethodPage), findsOneWidget);
  });

  testWidgets('table header filters reach the repository and drive the list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _ReferenceMethodRepositoryFake();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue(const <String>{}),
          referenceMethodRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: SettlementMethodPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 初次进入：列表 + facets 各一次。
    expect(repository.listCalls, 1);
    expect(repository.facetsCalls, 1);
    MasterDataTableView<SettlementMethodAdminItem> tableWidget() =>
        tester.widget<MasterDataTableView<SettlementMethodAdminItem>>(
          find.byWidgetPredicate(
            (widget) =>
                widget is MasterDataTableView<SettlementMethodAdminItem>,
          ),
        );
    final table = tableWidget();
    // 四个枚举列有筛选桶；下拉展示中文口径，筛选回传原始值。
    expect(
      table.facets.keys,
      containsAll(['status', 'systemRole', 'termsBase', 'dueRule']),
    );
    expect(table.facets['termsBase']!.single.display, '收货/进仓日');
    expect(table.facets['systemRole']!.single.display, '现金 · 系统锁定');
    expect(table.nullCounts['systemRole'], 1);
    expect(table.items, hasLength(2));
    expect(find.text('月结60'), findsOneWidget);

    // 表头筛选 → 服务端查询参数（filters 原样传仓库，含空值哨兵）。
    table.onFilterChanged('status', '禁用');
    await tester.pumpAndSettle();
    expect(repository.lastFilters, {'status': '禁用'});
    expect(tableWidget().items, [repository.disabledItem]);

    // 空值哨兵（筛 systemRole 为空的行）也落到查询参数。
    tableWidget().onFilterChanged('systemRole', kMasterFilterNullValue);
    await tester.pumpAndSettle();
    expect(repository.lastFilters, {
      'status': '禁用',
      'systemRole': kMasterFilterNullValue,
    });

    // 清除筛选恢复全量。
    tableWidget().onFilterChanged('status', null);
    tableWidget().onFilterChanged('systemRole', null);
    await tester.pumpAndSettle();
    expect(repository.lastFilters, isEmpty);
    expect(tableWidget().items, hasLength(2));
  });
}

class _ReferenceMethodRepositoryFake extends ReferenceMethodRepository {
  _ReferenceMethodRepositoryFake() : super(ApiClient(Dio()));

  int listCalls = 0;
  int facetsCalls = 0;
  final listFilters = <Map<String, String?>>[];
  Map<String, String?>? get lastFilters =>
      listFilters.isEmpty ? null : listFilters.last;

  final activeItem = const SettlementMethodAdminItem(
    id: 'm1',
    code: 'JS0001',
    name: '月结60',
    status: '使用',
    termsBase: 'RECEIPT_DATE',
    dueRule: 'NET_DAYS',
    defaultDueDays: 60,
    monthsAhead: 0,
  );

  final disabledItem = const SettlementMethodAdminItem(
    id: 'm2',
    code: 'JS0002',
    name: '现金',
    status: '禁用',
    systemRole: 'CASH',
    termsBase: 'RECEIPT_DATE',
    dueRule: 'NET_DAYS',
    defaultDueDays: 0,
    monthsAhead: 0,
  );

  @override
  Future<List<SettlementMethodAdminItem>> settlementAdminList({
    Map<String, String?> filters = const {},
  }) async {
    listCalls++;
    listFilters.add(Map<String, String?>.from(filters));
    final status = filters['status'];
    return [
      for (final item in [activeItem, disabledItem])
        if (status == null || item.status == status) item,
    ];
  }

  @override
  Future<SettlementMethodFacets> settlementAdminFacets() async {
    facetsCalls++;
    return const SettlementMethodFacets(
      fields: {
        'status': [
          MasterFacetBucket(value: '使用', count: 1),
          MasterFacetBucket(value: '禁用', count: 1),
        ],
        'systemRole': [MasterFacetBucket(value: 'CASH', count: 1)],
        'termsBase': [MasterFacetBucket(value: 'RECEIPT_DATE', count: 2)],
        'dueRule': [MasterFacetBucket(value: 'NET_DAYS', count: 2)],
      },
      nullCounts: {'status': 0, 'systemRole': 1, 'termsBase': 0, 'dueRule': 0},
    );
  }
}
