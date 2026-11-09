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

import '../../helpers/badge_summary_fixture.dart';

void main() {
  testWidgets('研发201条摘要按阶梯批次读完，完成后本地列表无额外读取', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final api = _RdApi(rowCount: 201);
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
    final table = tester.widget<MasterDataTableView<RdTaskRow>>(
      find.byType(MasterDataTableView<RdTaskRow>),
    );
    expect(table.items, hasLength(201));
    expect(table.items.last.id, 'rd-200');
    // 2026-11-08 阶梯完整读取：201 行 = 50 → 50 → 100 → 200（末批 1 行）。
    expect(api.queries.map((query) => query['page']), [1, 2, 2, 2]);
    expect(api.queries.map((query) => query['size']), [50, 50, 100, 200]);
    await tester.pump(const Duration(seconds: 1));
    expect(api.queries, hasLength(4));
    expect(tester.takeException(), isNull);
  });
  testWidgets('研发完整类别列表连续读取，筛选不裁剪为假空', (tester) async {
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
    expect(table().items.map((row) => row.category), ['BOM', 'SAMPLE']);
    expect(table().totalPages, 1);
    // 默认 2 行：阶梯首批 (1,50) 一次读完。
    expect(api.queries.map((query) => query['size']), [50]);
    final categoryCodes = {'BOM', 'DESIGN', 'SAMPLE', 'TRIAL', 'ECN', 'OTHER'};
    expect(
      table().facets['category']!.map((bucket) => bucket.value).toSet(),
      categoryCodes,
      reason: '固定类别桶必须覆盖其他页类别，不得取当前页样本',
    );
    expect(table().facets.containsKey('status'), isFalse);
    expect(find.byKey(const Key('rd-task-category-filter')), findsNothing);
    table().onFilterChanged('category', 'SAMPLE');
    await tester.pumpAndSettle();
    expect(api.queries.last['category'], 'SAMPLE');
    expect(api.queries.last['page'], 1);
    expect(table().items.single.category, 'SAMPLE');
    expect(table().totalPages, 1);
    expect(find.text('当前筛选下没有研发任务'), findsNothing);

    table().onFilterChanged('category', null);
    await tester.pumpAndSettle();
    expect(api.queries.last.containsKey('category'), isFalse);
    expect(table().items.map((row) => row.category), ['BOM', 'SAMPLE']);
    expect(
      table().facets['category']!.map((bucket) => bucket.value).toSet(),
      categoryCodes,
      reason: '完整快照仍使用完整类别枚举，不随行样本变化',
    );
    expect(tester.takeException(), isNull);
    final beforeHistory = api.queries.length;
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('rd-task-segments')),
        matching: find.text('历史单据'),
      ),
    );
    await tester.pumpAndSettle();
    final historyReads = api.queries.skip(beforeHistory).toList();
    expect(historyReads.first['page'], 1);
    expect(historyReads.every((query) => query['status'] == 'done'), isTrue);
    expect(table().currentPage, 1);
    expect(table().facets['status']!.map((bucket) => bucket.value), [
      'DONE',
      'CANCELED',
    ]);
    await tester.tap(find.text('优先级'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('紧急').last);
    await tester.pumpAndSettle();
    expect(api.queries.last['search.priority'], 'URGENT');
    table().onFilterChanged('status', 'CANCELED');
    await tester.pumpAndSettle();
    expect(api.queries.last['search.status'], 'CANCELED');
    expect(api.queries.last['status'], 'done');
    await tester.tap(find.text('任务号'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      'HEADER%_',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.queries.last['search.taskNo'], 'HEADER%_');
    await tester.tap(find.text('截止'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      '2026-10-28',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(api.queries.last['search.dueDate'], '2026-10-28');
    table().onSortChange!('dueDate', false);
    await tester.pumpAndSettle();
    expect(api.queries.last['sort'], 'dueDate');
    expect(api.queries.last['order'], 'desc');
    expect(api.queries.last['search.priority'], 'URGENT');
    expect(api.queries.last['search.status'], 'CANCELED');
    expect(api.queries.last['search.taskNo'], 'HEADER%_');
    expect(
      api.queries.firstWhere((query) => query['sort'] == 'dueDate')['page'],
      1,
    );
    expect(table().currentPage, 1);
    expect(tester.takeException(), isNull);
  });
}

class _RdApi extends ApiClient {
  _RdApi({this.rowCount = 2}) : super(Dio());
  final int rowCount;
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
    final size = query?['size'] as int? ?? 20;
    final allRows = [
      for (var index = 0; index < rowCount; index++)
        {
          'id': 'rd-$index',
          'taskNo': 'RD-$index',
          'title': '待完成的工作$index',
          'category': index.isEven ? 'BOM' : 'SAMPLE',
          'status': 'OPEN',
          'priority': 'NORMAL',
          'rowVersion': 1,
        },
    ];
    final matching = allRows
        .where((row) => category == null || row['category'] == category)
        .toList();
    return {
      'items': matching.skip((page - 1) * size).take(size).toList(),
      'page': page,
      'size': size,
      'total': matching.length,
      'totalPages': (matching.length / size).ceil(),
    };
  }
}
