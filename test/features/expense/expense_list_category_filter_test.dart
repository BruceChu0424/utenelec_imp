// 我的报销列表「类别」表头筛选冒烟断言（2026-09-16）：
// 固定八类桶（value=类别码）下推后端 category 参数并回第 1 页；与状态筛选正交。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/expense/pages/expense_list_page.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('expense category header facet is pushed to the backend query', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _ExpenseApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ExpenseListPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<ExpenseClaim>>(
      find.byKey(const Key('expense-list-table')),
    );
    expect(table.facets.keys, containsAll(<String>['status', 'category']));
    expect(
      table.facets['category']?.map((bucket) => bucket.value),
      containsAll(<String>['TRANSPORT', 'TRAVEL', 'MEAL', 'OFFICE', 'OTHER']),
    );
    expect(
      table.facets['category']
          ?.singleWhere((b) => b.value == 'TRANSPORT')
          .label,
      '交通费',
    );

    api.lastQuery = null;
    table.onFilterChanged('category', 'TRANSPORT');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['category'], 'TRANSPORT');
    expect(api.lastQuery?['page'], 1, reason: '换筛选回第 1 页');

    final refreshed = tester.widget<MasterDataTableView<ExpenseClaim>>(
      find.byKey(const Key('expense-list-table')),
    );
    expect(refreshed.filters['category'], 'TRANSPORT');
    // 状态桶 value=枚举名（小写），repo 统一转 apiValue（大写）回传。
    refreshed.onFilterChanged('status', 'paid');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['status'], 'PAID');
    expect(api.lastQuery?['category'], 'TRANSPORT');
    expect(tester.takeException(), isNull);
  });

  testWidgets('claimNo header filter and sort hit the backend (2026-09-25)', (
    tester,
  ) async {
    // 单号列统一：报销单号列头值筛选（服务端精确匹配）与排序（claimNo 白名单）
    // 下推后端；桶来自 facets?queue=mine 的 claimNos 键。
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _ExpenseApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ExpenseListPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<ExpenseClaim>>(
      find.byKey(const Key('expense-list-table')),
    );
    expect(table.facets.keys, contains('claimNo'));
    expect(table.facets['claimNo']!.single.value, 'BX2026-09-01-0001');
    expect(
      table.columns.where((c) => c.key == 'claimNo').single.sortable,
      isTrue,
    );

    api.lastQuery = null;
    table.onFilterChanged('claimNo', 'BX2026-09-01-0001');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['claimNo'], 'BX2026-09-01-0001');
    expect(api.lastQuery?['page'], 1, reason: '换单号筛选回第 1 页');

    tester
        .widget<MasterDataTableView<ExpenseClaim>>(
          find.byKey(const Key('expense-list-table')),
        )
        .onSortChange
        ?.call('claimNo', true);
    await tester.pumpAndSettle();
    expect(api.lastQuery?['sort'], 'claimNo');
    expect(api.lastQuery?['order'], 'asc');
    expect(tester.takeException(), isNull);
  });
}

class _ExpenseApi extends ApiClient {
  _ExpenseApi() : super(Dio());

  Map<String, dynamic>? lastQuery;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    // 2026-09-25 单号列统一：我的报销单号桶走 facets?queue=mine。
    if (path.contains('/facets')) {
      return <String, dynamic>{
        'departments': const <Map<String, dynamic>>[],
        'months': const <Map<String, dynamic>>[],
        'categories': const <Map<String, dynamic>>[],
        'claimNos': const [
          {
            'value': 'BX2026-09-01-0001',
            'label': 'BX2026-09-01-0001',
            'count': 1,
          },
        ],
      };
    }
    if (path.contains('/mine')) {
      lastQuery = query == null ? null : Map<String, dynamic>.from(query);
      return {
        'items': [
          {
            'id': 'claim-1',
            'applicantId': 'emp-1',
            'applicantName': '王小明',
            'title': '差旅报销',
            'status': 'PAID',
            'totalAmount': 1200.5,
            'createdAt': '2026-09-01T02:00:00Z',
            'submittedAt': '2026-09-01T03:00:00Z',
            'approvedAt': '2026-09-02T03:00:00Z',
            'paidAt': '2026-09-03T03:00:00Z',
            'items': [
              {
                'id': 'item-1',
                'category': 'TRAVEL',
                'amount': 1200.5,
                'date': '2026-08-30',
                'description': '住宿',
              },
            ],
          },
        ],
        'page': 1,
        'size': 24,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{'items': <Map<String, dynamic>>[]};
  }
}
