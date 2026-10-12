import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/rd_task/models/rd_task.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  testWidgets('研发类别筛选覆盖服务端全集，翻页不裁剪当页为假空', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _RdApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue({}),
          isSuperAdminProvider.overrideWithValue(false),
          fixedBadgeSummaryOverride(badgeSummaryFixture()),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RdTaskPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    MasterDataTableView<RdTaskRow> table() =>
        tester.widget(find.byType(MasterDataTableView<RdTaskRow>));
    expect(table().items.single.category, 'BOM');
    expect(table().totalPages, 2);
    expect(table().facets, isEmpty, reason: '当前页样本不应成为全局筛选桶');

    final category = tester.widget<UtenDropdownField>(
      find.byKey(const Key('rd-task-category-filter')),
    );
    category.onChanged('SAMPLE');
    await tester.pumpAndSettle();
    expect(api.queries.last['category'], 'SAMPLE');
    expect(api.queries.last['page'], 1);
    expect(table().items.single.category, 'SAMPLE');
    expect(table().totalPages, 1);
    expect(find.text('当前筛选下没有研发任务'), findsNothing);

    tester
        .widget<UtenDropdownField>(
          find.byKey(const Key('rd-task-category-filter')),
        )
        .onChanged('');
    await tester.pumpAndSettle();
    expect(api.queries.last.containsKey('category'), isFalse);
    table().onPageChange!(2);
    await tester.pumpAndSettle();
    expect(api.queries.last['page'], 2);
    expect(table().items.single.category, 'SAMPLE');
    expect(table().facets, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _RdApi extends ApiClient {
  _RdApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/rd-tasks') return const {};
    queries.add(Map<String, dynamic>.from(query ?? const {}));
    final category = query?['category'] as String?;
    final page = query?['page'] as int? ?? 1;
    final rowCategory = category ?? (page == 1 ? 'BOM' : 'SAMPLE');
    return {
      'items': [
        {
          'id': 'rd-$rowCategory',
          'taskNo': 'RD-$rowCategory',
          'title': '待完成的 $rowCategory 工作',
          'category': rowCategory,
          'status': 'OPEN',
          'priority': 'NORMAL',
          'rowVersion': 1,
        },
      ],
      'page': page,
      'size': 1,
      'total': category == null ? 2 : 1,
      'totalPages': category == null ? 2 : 1,
    };
  }
}
