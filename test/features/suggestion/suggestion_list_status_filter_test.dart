// 建议箱列表（2026-09-10 状态表头筛选下推后端 status）。
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/suggestion/models/suggestion.dart';
import 'package:uten_imp/features/suggestion/pages/suggestion_list_page.dart';
import 'package:uten_imp/features/suggestion/providers/suggestion_providers.dart';
import 'package:uten_imp/features/suggestion/repositories/suggestion_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakeSuggestionRepository extends Fake implements SuggestionRepository {
  final List<Map<String, dynamic>> listCalls = [];

  @override
  Future<PagedResult<Suggestion>> list({
    bool mine = false,
    SuggestionCategory? category,
    SuggestionStatus? status,
    int page = 1,
    int size = 20,
  }) async {
    listCalls.add({
      'mine': mine,
      'category': category?.name,
      'status': status?.name,
      'page': page,
    });
    return PagedResult(
      items: [
        Suggestion(
          id: 's-1',
          submitterId: 'emp-1',
          submitterName: '王小明',
          category: SuggestionCategory.process,
          title: '优化领料流程',
          content: '建议合并两次扫码',
          status: SuggestionStatus.reviewing,
          submittedAt: DateTime(2026, 9, 10, 9),
        ),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }
}

void main() {
  testWidgets('status header facet is pushed to the backend query', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeSuggestionRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionRepositoryProvider.overrideWithValue(repo),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SuggestionListPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<Suggestion>>(
      find.byKey(const Key('suggestion-list-table')),
    );
    expect(table.facets['status']!.map((b) => b.value), [
      'submitted',
      'reviewing',
      'resolved',
      'rejected',
    ]);
    expect(table.filters['status'], isNull);

    table.onFilterChanged('status', 'resolved');
    await tester.pumpAndSettle();

    expect(repo.listCalls.last['status'], 'resolved');
    expect(repo.listCalls.last['page'], 1, reason: '换筛选回第 1 页');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('category header facet is pushed to the backend query', (
    tester,
  ) async {
    // 类别列固定枚举桶（六类，2026-09-16）：value=枚举名（后端 category 码），
    // 选桶 → repository.list 收到 category 并回第 1 页；与状态筛选正交叠加。
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeSuggestionRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionRepositoryProvider.overrideWithValue(repo),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SuggestionListPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final table = tester.widget<MasterDataTableView<Suggestion>>(
      find.byKey(const Key('suggestion-list-table')),
    );
    expect(table.facets.keys, containsAll(<String>['status', 'category']));
    expect(
      table.facets['category']?.map((bucket) => bucket.value),
      containsAll(<String>['product', 'process', 'welfare', 'other']),
    );

    table.onFilterChanged('category', 'process');
    await tester.pumpAndSettle();
    expect(repo.listCalls.last['category'], 'process');
    expect(repo.listCalls.last['page'], 1, reason: '换筛选回第 1 页');

    final refreshed = tester.widget<MasterDataTableView<Suggestion>>(
      find.byKey(const Key('suggestion-list-table')),
    );
    expect(refreshed.filters['category'], 'process');
    refreshed.onFilterChanged('status', 'reviewing');
    await tester.pumpAndSettle();
    expect(repo.listCalls.last['status'], 'reviewing');
    expect(repo.listCalls.last['category'], 'process');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('筛选空结果留表头，清除后恢复记录，真正空箱保留唯一提交入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final api = _FilteringSuggestionApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          suggestionRepositoryProvider.overrideWithValue(
            DioSuggestionRepository(api),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SuggestionListPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    MasterDataTableView<Suggestion> table() =>
        tester.widget(find.byKey(const Key('suggestion-list-table')));
    expect(table().items, hasLength(1));

    table().onFilterChanged('status', 'resolved');
    await tester.pumpAndSettle();
    expect(api.queries.last['status'], 'resolved');
    expect(api.queries.last['page'], 1);
    expect(table().items, isEmpty);
    expect(table().filters['status'], 'resolved');
    expect(find.text('类别'), findsOneWidget);
    expect(
      table().facets['status']!.map((bucket) => bucket.value),
      contains('reviewing'),
    );
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('提交建议'), findsNothing);

    table().onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(api.queries.last.containsKey('status'), isFalse);
    expect(table().items.single.title, '优化领料流程');

    table().onFilterChanged('category', 'product');
    await tester.pumpAndSettle();
    expect(api.queries.last['category'], 'product');
    expect(table().items, isEmpty);
    expect(find.text('状态'), findsOneWidget);
    expect(
      table().facets['category']!.map((bucket) => bucket.value),
      contains('process'),
    );
    expect(find.byType(FloatingActionButton), findsOneWidget);
    table().onFilterChanged('category', null);
    await tester.pumpAndSettle();
    expect(api.queries.last.containsKey('category'), isFalse);
    expect(table().items, hasLength(1));

    api.empty = true;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SuggestionListPage)),
      listen: false,
    );
    await container.read(suggestionListProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('suggestion-list-table')), findsNothing);
    expect(find.text('提交建议'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

/// 经过实际 DioSuggestionRepository 序列化的查询，按服务端筛选条件返回真空集。
class _FilteringSuggestionApi extends ApiClient {
  _FilteringSuggestionApi() : super(Dio());

  final List<Map<String, dynamic>> queries = [];
  bool empty = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != '/suggestions') return const {};
    final parameters = Map<String, dynamic>.from(query ?? const {});
    queries.add(parameters);
    final matches =
        !empty &&
        (parameters['status'] == null || parameters['status'] == 'reviewing') &&
        (parameters['category'] == null || parameters['category'] == 'process');
    return {
      'items': [
        if (matches)
          {
            'id': 's-1',
            'submitterId': 'emp-1',
            'submitterName': '王小明',
            'category': 'process',
            'title': '优化领料流程',
            'content': '建议合并两次扫码',
            'status': 'reviewing',
            'submittedAt': '2026-09-10T09:00:00+08:00',
          },
      ],
      'page': parameters['page'],
      'size': parameters['size'],
      'total': matches ? 1 : 0,
      'totalPages': 1,
    };
  }
}
