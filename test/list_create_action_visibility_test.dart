import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/expense/providers/expense_counts_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/pages/expense_list_page.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/features/suggestion/models/suggestion.dart';
import 'package:uten_imp/features/suggestion/pages/suggestion_list_page.dart';
import 'package:uten_imp/features/suggestion/providers/suggestion_providers.dart';
import 'package:uten_imp/features/suggestion/repositories/suggestion_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

late SharedPreferences _preferences;

class _ExpenseRepository extends Fake implements ExpenseRepository {
  _ExpenseRepository(this.items);

  final List<ExpenseClaim> items;

  @override
  Future<PagedResult<ExpenseClaim>> listMine({
    Iterable<ExpenseClaimStatus>? statuses,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    String? category,
  }) async {
    return PagedResult(
      items: items,
      page: 1,
      size: size,
      total: items.length,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }
}

class _SuggestionRepository extends Fake implements SuggestionRepository {
  _SuggestionRepository(this.items);

  final List<Suggestion> items;

  @override
  Future<PagedResult<Suggestion>> list({
    bool mine = false,
    SuggestionCategory? category,
    SuggestionStatus? status,
    int page = 1,
    int size = 20,
  }) async {
    return PagedResult(
      items: items,
      page: 1,
      size: size,
      total: items.length,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }
}

Widget _expenseApp(List<ExpenseClaim> items, {bool canApply = true}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_preferences),
      expenseRepositoryProvider.overrideWithValue(_ExpenseRepository(items)),
      currentPermissionsProvider.overrideWithValue({
        if (canApply) Perm.expenseApply,
      }),
      expenseCountsProvider.overrideWith((ref) => const ExpenseCounts()),
    ],
    child: const MaterialApp(
      locale: Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ExpenseListPage(),
    ),
  );
}

Widget _suggestionApp(List<Suggestion> items) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_preferences),
      suggestionRepositoryProvider.overrideWithValue(
        _SuggestionRepository(items),
      ),
    ],
    child: const MaterialApp(home: SuggestionListPage()),
  );
}

void _useCompactViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final _createdAt = DateTime(2026, 7, 30);

final _claim = ExpenseClaim(
  id: 'expense-1',
  claimNo: 'BX20260730000001',
  applicantId: 'employee-1',
  applicantName: '测试员工',
  title: '差旅报销',
  items: [],
  totalAmount: 120,
  status: ExpenseClaimStatus.draft,
  createdAt: _createdAt,
);

final _suggestion = Suggestion(
  id: 'suggestion-1',
  submitterId: 'employee-1',
  submitterName: '测试员工',
  category: SuggestionCategory.process,
  title: '优化审批',
  content: '减少重复录入。',
  status: SuggestionStatus.submitted,
  submittedAt: _createdAt,
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets('expense empty state owns the only create action', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_expenseApp(const []));
    await tester.pumpAndSettle();

    expect(find.text('新建报销'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('expense non-empty state exposes header create button', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_expenseApp([_claim]));
    await tester.pumpAndSettle();

    // 2026-09-19 V608 对齐 purchase 范式：新建入口迁到页面头行按钮，不再出 FAB。
    expect(find.text('新建报销'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('expense creation stays hidden without apply permission', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_expenseApp([_claim], canApply: false));
    await tester.pumpAndSettle();
    expect(find.text('新建报销'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('suggestion empty state owns the only create action', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_suggestionApp(const []));
    await tester.pumpAndSettle();

    expect(find.text('提交建议'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('suggestion non-empty state exposes create action as FAB', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_suggestionApp([_suggestion]));
    await tester.pumpAndSettle();

    expect(find.text('提建议'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
