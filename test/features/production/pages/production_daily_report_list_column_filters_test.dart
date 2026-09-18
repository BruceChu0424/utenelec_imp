// 生产日报列表「表头筛选生效」冒烟断言：
// 车间桶（departments/tree 展平）回传 departmentId，筛选后重拉回第 1 页。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_list_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('daily report headers send workshop filter to API', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _DailyFilterApi();
    final router = GoRouter(
      initialLocation: '/production/daily-reports',
      routes: [
        GoRoute(
          path: '/production/daily-reports',
          builder: (_, _) => const ProductionDailyReportListPage(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    MasterDataTableView<ProductionDailyReportListItem> tableWidget() =>
        tester.widget(
          find.byWidgetPredicate(
            (widget) =>
                widget is MasterDataTableView<ProductionDailyReportListItem>,
          ),
        );
    final table = tableWidget();
    expect(table.facets.keys, contains('workshop'));
    expect(
      table.facets['workshop']?.map((bucket) => bucket.value),
      contains('dept-1'),
    );

    api.lastQuery = null;
    table.onFilterChanged('workshop', 'dept-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['departmentId'], 'dept-1');
    expect(api.lastQuery?['page'], 1);
    expect(tester.takeException(), isNull);
  });
}

class _DailyFilterApi extends ApiClient {
  _DailyFilterApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query == null ? null : Map<String, dynamic>.from(query);
    return {
      'items': [
        {
          'id': 'daily-1',
          'billNo': 'RB26080001',
          'billDate': '2026-08-31',
          'departmentId': 'dept-1',
          'status': 0,
        },
      ],
      'page': 1,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('departments')) {
      return const [
        {
          'id': 'dept-root',
          'name': '生产部',
          'children': [
            {'id': 'dept-1', 'name': '一车间'},
          ],
        },
      ];
    }
    return const [];
  }
}
