import 'dart:async';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/pages/expense_claim_edit_page.dart';
import 'package:uten_imp/features/expense/widgets/expense_editable_items.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/features/expense/repositories/expense_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('EXPENSE_UI_CAPTURE');

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'expense-ui-user',
      employeeId: 'expense-ui-employee',
      code: 'E-UI',
      name: '张申请',
      department: '综合营销部',
      permissions: [Perm.expenseApply],
    ),
  );
}

ExpenseClaim _claim({int rows = 3}) => ExpenseClaim(
  id: 'expense-ui-claim',
  claimNo: 'BX20261103000001',
  applicantId: 'expense-ui-employee',
  applicantName: '张申请',
  departmentName: '综合营销部',
  title: '客户现场服务差旅报销',
  remark: '客户设备验收与现场服务，补充住宿及交通原始凭证。',
  items: [
    for (var i = 0; i < rows; i++)
      ExpenseItem(
        id: 'expense-ui-item-$i',
        category: ExpenseCategory.travel,
        amount: 35,
        date: DateTime(2026, 11, 2),
        description: '第${i + 1}项：客户现场服务交通和住宿费用',
      ),
  ],
  totalAmount: rows * 35,
  status: ExpenseClaimStatus.rejected,
  createdAt: DateTime(2026, 11, 3),
  rejectedAt: DateTime(2026, 11, 3, 9),
  rejectReason: '请补充住宿发票原件后重新提交',
  rejectedByName: '财务初核员',
  version: 7,
);

class _Repository extends Fake implements ExpenseRepository {
  _Repository({int rows = 3}) : claim = _claim(rows: rows);
  final ExpenseClaim claim;
  final updates = <ExpenseClaimCreateInput>[];
  Completer<ExpenseClaim>? pendingSave;

  @override
  Future<ExpenseClaim> getById(String id) async => claim;

  @override
  Future<ExpenseClaim> update(String id, ExpenseClaimCreateInput input) async {
    updates.add(input);
    return pendingSave?.future ?? Future.value(claim);
  }
}

Future<GoRouter> _pump(
  WidgetTester tester,
  _Repository repository, {
  required GlobalKey boundaryKey,
  double width = 1440,
  bool dark = false,
  bool create = false,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: create ? '/expense/new' : '/expense/expense-ui-claim/edit',
    routes: [
      GoRoute(
        path: '/expense/new',
        builder: (_, _) => const ExpenseClaimEditPage(),
      ),
      GoRoute(
        path: '/expense/:id/edit',
        builder: (_, state) =>
            ExpenseClaimEditPage(claimId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/expense/:id',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('已保存的报销详情'))),
      ),
    ],
  );
  addTearDown(router.dispose);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final theme = dark ? buildDarkTheme() : buildLightTheme();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        apiBaseUrlProvider.overrideWithValue('https://expense-ui.invalid/api'),
        apiClientProvider.overrideWithValue(
          ApiClient(
            Dio(BaseOptions(baseUrl: 'https://expense-ui.invalid/api')),
          ),
        ),
        currentPermissionsProvider.overrideWithValue({Perm.expenseApply}),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        expenseRepositoryProvider.overrideWithValue(repository),
        expenseSettingsProvider.overrideWith(
          (_) async => const ExpenseSettings(companyName: '中山市优腾'),
        ),
      ],
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: _capture ? auditScreenshotTheme(theme) : theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final variant in [
    (name: 'new-desktop', width: 1440.0, dark: false, scale: 1.0, create: true),
    (
      name: 'edit-desktop',
      width: 1440.0,
      dark: false,
      scale: 1.0,
      create: false,
    ),
    (
      name: 'edit-mobile-dark-large',
      width: 390.0,
      dark: true,
      scale: 1.4,
      create: false,
    ),
  ]) {
    testWidgets('real expense form ${variant.name} keeps actions reachable', (
      tester,
    ) async {
      final boundary = GlobalKey();
      await _pump(
        tester,
        _Repository(),
        boundaryKey: boundary,
        width: variant.width,
        dark: variant.dark,
        create: variant.create,
        textScale: variant.scale,
      );
      expect(tester.takeException(), isNull);
      final actions = find.widgetWithText(
        UtenButton,
        variant.create ? '保存并补充凭证' : '保存',
      );
      expect(actions, findsOneWidget);
      final actionRect = tester.getRect(actions);
      expect(actionRect.bottom, lessThanOrEqualTo(1000));
      expect(actionRect.right, lessThanOrEqualTo(variant.width));
      if (_capture) {
        await saveAuditScreenshot(tester, boundary, 'expense-${variant.name}');
      }
    });
  }

  testWidgets(
    '1000 rows survive scrolling, repeated save and interrupted response',
    (tester) async {
      final repository = _Repository(rows: 1000)
        ..pendingSave = Completer<ExpenseClaim>();
      final router = await _pump(tester, repository, boundaryKey: GlobalKey());
      final grid = tester.widget<ExpenseEditableItems>(
        find.byType(ExpenseEditableItems),
      );
      final allIds = grid.controller.rows.map((row) => row.id).toSet();
      expect(grid.controller.length, 1000);
      expect(
        find.byType(TextField).evaluate().length,
        lessThan(100),
        reason: 'large documents mount only the visible editing window',
      );
      final vertical = tester
          .widgetList<Scrollable>(find.byType(Scrollable))
          .firstWhere((value) => value.axisDirection == AxisDirection.down);
      await tester.drag(find.byWidget(vertical), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(grid.controller.rows.map((row) => row.id).toSet(), allIds);
      final scrollState = tester.state<ScrollableState>(
        find
            .byWidgetPredicate(
              (value) =>
                  value is Scrollable &&
                  value.axisDirection == AxisDirection.down,
            )
            .first,
      );
      scrollState.position.jumpTo(0);
      await tester.pumpAndSettle();
      final title = find.widgetWithText(TextField, '报销标题 *').first;
      await tester.enterText(title, '千行报销修订');
      final save = find.widgetWithText(UtenButton, '保存');
      tester.widget<UtenButton>(save).onPressed?.call();
      await tester.pumpAndSettle();
      expect(
        repository.updates,
        isEmpty,
        reason: 'the server supports at most 100 expense lines per claim',
      );
      expect(
        grid.controller.length,
        1000,
        reason: 'rejecting an oversized save must preserve every raw row',
      );
      expect(grid.controller.rows.map((row) => row.id).toSet(), allIds);
      grid.controller.removeRows(grid.controller.rows.skip(100).toList());
      await tester.pumpAndSettle();
      expect(grid.controller.length, 100);

      // A held response exposes the actual click guard; no timing assumptions.
      for (var i = 0; i < 12; i++) {
        tester.widget<UtenButton>(save).onPressed?.call();
        await tester.pump();
      }
      expect(
        repository.updates,
        hasLength(1),
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data ?? '')
            .join(' | '),
      );
      expect(repository.updates.single.items, hasLength(100));
      expect(repository.updates.single.title, '千行报销修订');
      expect(repository.updates.single.expectedVersion, 7);
      expect(
        repository.updates.single.items.map((row) => row.id).toSet(),
        hasLength(100),
      );
      // Leaving while an update response is pending must not replay the write or
      // navigate back after the original page has been disposed.
      router.go('/expense/expense-ui-claim');
      await tester.pumpAndSettle();
      repository.pendingSave!.complete(repository.claim);
      await tester.pumpAndSettle();
      expect(repository.updates, hasLength(1));
      expect(find.text('已保存的报销详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
