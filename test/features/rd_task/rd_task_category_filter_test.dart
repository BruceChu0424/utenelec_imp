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
    expect(table().items, hasLength(101));
    expect(table().items.every((row) => row.category == 'BOM'), isTrue);
    expect(api.queries.map((query) => query['page']), [1, 2]);
    expect(api.queries.every((query) => query['size'] == 100), isTrue);
    expect(table().totalPages, 1);
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

  testWidgets('已完成读取完整服务端阶段，不用当前批状态假筛选', (tester) async {
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
    expect(table().facets['status']!.map((bucket) => bucket.value), [
      'DONE',
      'CANCELED',
    ]);
    final statuses = [
      for (var index = 0; index < 102; index++)
        index.isEven ? 'DONE' : 'CANCELED',
    ];
    expect(table().items.map((row) => row.status), statuses);
    expect(api.queries.map((query) => query['page']), [1, 2]);
    expect(api.queries.every((query) => query['size'] == 100), isTrue);
    expect(table().totalPages, 1);
    expect(table().items.map((row) => table().columns.first.value(row)), [
      for (final status in statuses)
        status == 'DONE' ? 'BOM维护 · 已完成' : 'BOM维护 · 已取消',
    ]);
    final before = api.queries.length;
    // 旧状态偏好或旧回调不能再触发当页裁剪。
    table().onFilterChanged('status', '已完成');
    await tester.pumpAndSettle();
    expect(api.queries, hasLength(before));
    expect(table().items.map((row) => row.status), statuses);
    expect(table().filters['status'], isNull);
    expect(table().totalPages, 1);
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
    final page = parameters['page'] as int;
    final size = parameters['size'] as int;
    final done = parameters['status'] == 'done';
    final total = parameters.containsKey('category') ? 1 : (done ? 102 : 101);
    final start = (page - 1) * size;
    return {
      'items': [
        for (var index = start; index < total && index < start + size; index++)
          {
            'id': 'task-$category-$index',
            'taskNo': 'RD-$category-$index',
            'title': '跨页类别查询',
            'category': category,
            'status': switch (parameters['status']) {
              'in_progress' => 'IN_PROGRESS',
              'done' => index.isEven ? 'DONE' : 'CANCELED',
              _ => 'OPEN',
            },
            'priority': 'NORMAL',
            'rowVersion': 1,
          },
      ],
      'page': parameters['page'],
      'size': parameters['size'],
      'total': total,
      'totalPages': (total / size).ceil(),
    };
  }
}
