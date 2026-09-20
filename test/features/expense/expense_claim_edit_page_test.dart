// 报销新建/编辑页（V608）：编辑模式预填 + 驳回横幅 + 保存走 PUT + 大写合计。
// 页面保存成功后 context.go 跳详情 —— 测试必须包 GoRouter（含 :id/edit 路由）。
import 'package:flutter/material.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/pages/expense_claim_edit_page.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-1',
      employeeId: 'emp-1',
      code: 'E001',
      name: '张三',
      department: '研发部',
      roles: [],
      permissions: [Perm.expenseApply],
    ),
  );
}

class _FakeExpenseRepository extends Fake implements ExpenseRepository {
  ExpenseClaim? detail;
  final List<Map<String, dynamic>> updateCalls = [];

  @override
  Future<ExpenseClaim> getById(String id) async => detail!;

  @override
  Future<ExpenseClaim> update(String id, ExpenseClaimCreateInput input) async {
    updateCalls.add({'id': id, 'input': input});
    return detail!;
  }
}

ExpenseClaim _rejectedClaim({double amount = 300}) => ExpenseClaim(
  id: 'claim-1',
  claimNo: 'BX20260918000001',
  applicantId: 'emp-1',
  applicantName: '张三',
  departmentId: 'dept-1',
  departmentName: '研发部',
  title: '客户拜访差旅',
  items: [
    ExpenseItem(
      id: 'item-1',
      category: ExpenseCategory.travel,
      amount: amount,
      date: DateTime(2026, 9, 17),
      description: '住宿',
    ),
  ],
  totalAmount: amount,
  status: ExpenseClaimStatus.rejected,
  createdAt: DateTime(2026, 9, 18, 9),
  submittedAt: DateTime(2026, 9, 18, 10),
  rejectedAt: DateTime(2026, 9, 18, 11),
  rejectReason: '缺住宿发票',
  rejectedByName: '李财务',
);

Widget _app(_FakeExpenseRepository repo, SharedPreferences preferences) {
  final router = GoRouter(
    initialLocation: '/expense/claim-1/edit',
    routes: [
      GoRoute(
        path: '/expense/new',
        builder: (_, _) => const ExpenseClaimEditPage(),
      ),
      GoRoute(
        path: '/expense/:id/edit',
        builder: (_, s) =>
            ExpenseClaimEditPage(claimId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/expense/:id',
        builder: (_, _) => const SizedBox(key: Key('expense-detail-stub')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      currentPermissionsProvider.overrideWithValue({Perm.expenseApply}),
      expenseSettingsProvider.overrideWith(
        (ref) async => const ExpenseSettings(companyName: '测试公司'),
      ),
      expenseRepositoryProvider.overrideWithValue(repo),
      sharedPreferencesProvider.overrideWithValue(preferences),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.4)),
        child: child!,
      ),
      routerConfig: router,
    ),
  );
}

Future<void> _pump(WidgetTester tester, _FakeExpenseRepository repo) async {
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(_app(repo, preferences));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets('edit form at $width dp supports large text and dark mode', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _FakeExpenseRepository()
        ..detail = _rejectedClaim(amount: 9999999999.99);
      await _pump(tester, repo);
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('edit mode prefills rejected claim and shows reason banner', (
    tester,
  ) async {
    final repo = _FakeExpenseRepository()..detail = _rejectedClaim();
    await _pump(tester, repo);

    expect(find.text('编辑报销'), findsOneWidget);
    // 驳回横幅：原因 + 驳回人。
    expect(find.textContaining('缺住宿发票'), findsOneWidget);
    expect(find.textContaining('李财务'), findsOneWidget);
    // 预填标题与明细。
    expect(find.text('客户拜访差旅'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.textContaining('差旅费'), findsOneWidget);
    // 合计大写（银发〔1997〕393 号口径）。
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();
    expect(find.textContaining('人民币叁佰元整'), findsOneWidget);
  });

  testWidgets('save posts PUT with edited title and items', (tester) async {
    final repo = _FakeExpenseRepository()..detail = _rejectedClaim();
    await _pump(tester, repo);

    await tester.enterText(
      find.widgetWithText(TextField, '报销标题 *').first,
      '客户拜访差旅（修订）',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updateCalls.single['id'], 'claim-1');
    final input = repo.updateCalls.single['input'] as ExpenseClaimCreateInput;
    expect(input.title, '客户拜访差旅（修订）');
    expect(input.items.single.amount, 300);
    // 保存成功后回详情页。
    expect(find.byKey(const Key('expense-detail-stub')), findsOneWidget);
  });

  testWidgets('create mode keeps draft flow and blocks empty items', (
    tester,
  ) async {
    final repo = _FakeExpenseRepository();
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final router = GoRouter(
      initialLocation: '/expense/new',
      routes: [
        GoRoute(
          path: '/expense/new',
          builder: (_, _) => const ExpenseClaimEditPage(),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          currentPermissionsProvider.overrideWithValue({Perm.expenseApply}),
          expenseSettingsProvider.overrideWith(
            (ref) async => const ExpenseSettings(companyName: '测试公司'),
          ),
          expenseRepositoryProvider.overrideWithValue(repo),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新建报销'), findsOneWidget);
    // 新建无驳回横幅；存草稿/提交按钮就位（空明细时禁用由 onDisabledTap 提示）。
    expect(find.textContaining('驳回原因'), findsNothing);
    expect(find.text('保存并补充凭证'), findsOneWidget);
    expect(find.text('提交'), findsNothing);
  });
}
