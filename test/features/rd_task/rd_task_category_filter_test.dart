import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/rd_task/models/rd_task.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('类别表头查询其他页的任务，清除后保持工作阶段', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final api = _RecordingRdApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {Perm.rdTaskView}),
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
    expect(find.byKey(const Key('rd-task-category-filter')), findsNothing);
    expect(table().items.single.category, 'BOM');
    expect(table().facets.containsKey('status'), isFalse);
    expect(
      table().facets['category']!.map((bucket) => bucket.value),
      contains('DESIGN'),
    );

    table().onFilterChanged('category', 'DESIGN');
    await tester.pumpAndSettle();
    expect(api.queries.last['category'], 'DESIGN');
    expect(api.queries.last['status'], 'pending');
    expect(api.queries.last['page'], 1);
    expect(table().items.single.category, 'DESIGN');
    expect(table().columns.first.value(table().items.single), '设计 · 待处理');

    table().onFilterChanged('category', null);
    await tester.pumpAndSettle();
    expect(api.queries.last.containsKey('category'), isFalse);
    expect(api.queries.last['status'], 'pending');
    expect(table().filters['category'], isNull);

    table().onFilterChanged('category', 'DESIGN');
    await tester.pumpAndSettle();
    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();
    expect(api.queries.last['status'], 'in_progress');
    expect(
      api.queries.last['category'],
      'DESIGN',
      reason: '类别与工作阶段正交，跨阶段继续服务端完整筛选',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('已完成按服务端完整阶段分页，不用当前页状态假筛选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final api = _RecordingRdApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(const {Perm.rdTaskView}),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RdTaskPage(initialTab: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    MasterDataTableView<RdTaskRow> table() =>
        tester.widget(find.byType(MasterDataTableView<RdTaskRow>));
    expect(api.queries.last['status'], 'done');
    expect(table().facets.containsKey('status'), isFalse);
    expect(table().items.map((row) => row.status), ['DONE', 'CANCELED']);
    expect(table().totalPages, 2);
    expect(table().items.map((row) => table().columns.first.value(row)), [
      'BOM维护 · 已完成',
      'BOM维护 · 已取消',
    ]);
    final before = api.queries.length;
    // 旧状态偏好或旧回调不能再触发当页裁剪。
    table().onFilterChanged('status', '已完成');
    await tester.pumpAndSettle();
    expect(api.queries, hasLength(before));
    expect(table().items.map((row) => row.status), ['DONE', 'CANCELED']);
    expect(table().filters.containsKey('status'), isFalse);
    expect(table().totalPages, 2);
    expect(tester.takeException(), isNull);
  });
}

class _RecordingRdApi extends ApiClient {
  _RecordingRdApi() : super(Dio());
  final List<Map<String, dynamic>> queries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/rd-tasks') return const {};
    final parameters = Map<String, dynamic>.from(query ?? const {});
    queries.add(parameters);
    final category = parameters['category'] as String? ?? 'BOM';
    return {
      'items': [
        {
          'id': 'task-$category',
          'taskNo': 'RD-$category',
          'title': '跨页类别查询',
          'category': category,
          'status': switch (parameters['status']) {
            'in_progress' => 'IN_PROGRESS',
            'done' => 'DONE',
            _ => 'OPEN',
          },
          'priority': 'NORMAL',
          'rowVersion': 1,
        },
        if (parameters['status'] == 'done')
          {
            'id': 'task-canceled-$category',
            'taskNo': 'RD-CANCELED-$category',
            'title': '已取消任务',
            'category': category,
            'status': 'CANCELED',
            'priority': 'NORMAL',
            'rowVersion': 1,
          },
      ],
      'page': parameters['page'],
      'size': parameters['size'],
      'total': parameters.containsKey('category') ? 1 : 21,
      'totalPages': parameters.containsKey('category') ? 1 : 2,
    };
  }
}
