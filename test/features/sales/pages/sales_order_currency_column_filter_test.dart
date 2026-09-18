// 销售订货单列表「币种」表头筛选冒烟断言（2026-09-16）：
// currencies/dict 桶回传 currencyId；筛选后重拉回第 1 页。
// 订单表无仓库列（V51 起 sales_orders 只有 currency_id），订货段无仓库筛选。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('order headers send currency filter to API', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _OrderFilterApi();
    final router = GoRouter(
      initialLocation: '/sales/orders?status=draft',
      routes: [
        GoRoute(
          path: '/sales/orders',
          builder: (_, state) => SalesDocListPage(
            docType: SalesDocType.order,
            initialStatus: state.uri.queryParameters['status'],
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          salesMasterNameServiceProvider.overrideWithValue(
            SalesMasterNameService(api),
          ),
          currentPermissionsProvider.overrideWithValue(const <String>{}),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    MasterDataTableView<SalesDocListItem> tableWidget() => tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SalesDocListItem>,
      ),
    );
    final table = tableWidget();
    expect(table.facets.keys, containsAll(<String>['status', 'currency']));
    // 币种桶来自 currencies/dict：value=字典 id，label=币种名。
    expect(table.facets['currency']?.single.value, 'currency-1');
    expect(table.facets['currency']?.single.label, '美元');
    // 订单段无仓库列，不出仓库桶。
    expect(table.facets.containsKey('warehouse'), isFalse);

    api.lastQuery = null;
    table.onFilterChanged('currency', 'currency-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['currencyId'], 'currency-1');
    expect(api.lastQuery?['page'], 1);

    final refreshed = tableWidget();
    expect(refreshed.filters['currency'], 'currency-1');
    expect(tester.takeException(), isNull);
  });
}

class _OrderFilterApi extends ApiClient {
  _OrderFilterApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    if (path == '/sales/orders') {
      return const {
        'items': [
          {
            'id': 'order-1',
            'billNo': 'XS202608310001',
            'billDate': '2026-08-31',
            'clientId': 'client-1',
            'currencyId': 'currency-1',
            'status': 0,
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path == '/sales/orders/stats') {
      return const {
        'pendingProduction': 0,
        'inProduction': 0,
        'shippable': 0,
        'monthDone': 0,
      };
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('currencies')) {
      return const [
        {'id': 'currency-1', 'name': '美元'},
      ];
    }
    if (path.contains('clients')) {
      return const [
        {'id': 'client-1', 'name': '客户甲'},
      ];
    }
    return const [];
  }
}
