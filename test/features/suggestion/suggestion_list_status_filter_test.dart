// 建议箱列表（2026-09-10 状态表头筛选下推后端 status）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
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
    listCalls.add({'mine': mine, 'status': status?.name, 'page': page});
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
}
