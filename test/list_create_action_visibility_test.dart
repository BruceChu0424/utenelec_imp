import 'package:flutter/material.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
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
    String? sort,
    String? order,
    String? claimNo,
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

Widget _suggestionApp(List<Suggestion> items, {bool enlargedDark = false}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_preferences),
      suggestionRepositoryProvider.overrideWithValue(
        _SuggestionRepository(items),
      ),
    ],
    child: MaterialApp(
      theme: enlargedDark ? ThemeData.dark() : ThemeData.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(enlargedDark ? 1.5 : 1)),
        child: child!,
      ),
      home: const SuggestionListPage(),
    ),
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

  for (final width in [390.0, 1280.0]) {
    testWidgets('suggestion categories stay below the title at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_suggestionApp(const [], enlargedDark: true));
      await tester.pumpAndSettle();
      final appBar = tester.getRect(find.byType(UtenAppBar));
      final filters = tester.getRect(
        find.byType(UtenFilterToolbar<SuggestionScope>),
      );
      final create = tester.getRect(find.text('提建议'));
      expect(filters.top, greaterThanOrEqualTo(appBar.bottom));
      expect(filters.right, lessThanOrEqualTo(width));
      expect(create.center.dx, greaterThan(width / 2));
      expect(create.center.dy, greaterThan(425));
      expect(find.text('建议箱'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('expense empty state keeps the only create action floating', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_expenseApp(const []));
    await tester.pumpAndSettle();

    expect(find.text('新建报销'), findsOneWidget);
    expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
    expect(find.text('我的报销'), findsOneWidget);
    expect(find.textContaining('我的报销 ('), findsNothing);
    final create = find.byKey(const Key('expense-list-create'));
    expect(tester.getRect(create).top, greaterThan(400));
    expect(tester.getRect(create).right, lessThanOrEqualTo(600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('expense all categories retain one floating create action', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_expenseApp([_claim]));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExpenseListPage)),
    );
    for (final filter in ExpenseFilter.values) {
      container.read(expenseFilterProvider.notifier).state = filter;
      await tester.pumpAndSettle();
      expect(find.text('新建报销'), findsOneWidget, reason: filter.name);
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      expect(find.text('我的报销'), findsOneWidget);
      expect(find.textContaining('我的报销 ('), findsNothing);
      final create = find.byKey(const Key('expense-list-create'));
      expect(tester.getRect(create).top, greaterThan(400));
      expect(tester.getRect(create).right, lessThanOrEqualTo(600));
      if (filter == ExpenseFilter.draft) {
        final group = find.ancestor(
          of: create,
          matching: find.byType(UtenFloatingActionGroup),
        );
        expect(
          find.descendant(of: group, matching: find.text('删除所选草稿 (0)')),
          findsOneWidget,
          reason: '草稿新建与删除共享一个浮动组，不互相覆盖',
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('expense creation stays hidden without apply permission', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_expenseApp([_claim], canApply: false));
    await tester.pumpAndSettle();
    expect(find.text('新建报销'), findsNothing);
    expect(find.byType(UtenFloatingActionGroup), findsNothing);
  });

  testWidgets(
    'suggestion empty state keeps the create action in the floating group',
    (tester) async {
      _useCompactViewport(tester);
      await tester.pumpWidget(_suggestionApp(const []));
      await tester.pumpAndSettle();

      expect(find.text('提交建议'), findsNothing);
      expect(find.text('提建议'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(UtenFloatingActionGroup),
          matching: find.text('提建议'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('suggestion non-empty state exposes create action as FAB', (
    tester,
  ) async {
    _useCompactViewport(tester);
    await tester.pumpWidget(_suggestionApp([_suggestion]));
    await tester.pumpAndSettle();

    expect(find.text('提建议'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(UtenFloatingActionGroup),
        matching: find.text('提建议'),
      ),
      findsOneWidget,
    );
  });
}
