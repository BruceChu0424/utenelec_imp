import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_create_actions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

void main() {
  for (final readOnly in [false, true]) {
    testWidgets(readOnly ? '只读代操作隐藏草稿新建动作' : '只有查看权限时隐藏草稿新建动作', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authenticatedScopeProvider.overrideWithValue(
              AuthenticatedScope(userId: 'operator', readOnly: readOnly),
            ),
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue({
              Perm.financeExpenseView,
              if (readOnly) Perm.financeExpenseCreate,
            }),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DraftWorkspaceCreateButton(
                kinds: [DraftDocKind.financeExpense],
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('draft-workspace-create')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('新建菜单保留授权委外来源登记，不显示未授权类别', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: DraftWorkspaceCreateButton(
              kinds: [
                DraftDocKind.subcontractOrder,
                DraftDocKind.subcontractReturn,
                DraftDocKind.subcontractMaterialReturn,
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/subcontract/material-returns/new',
          builder: (_, _) => const Scaffold(body: Text('余料来源登记页')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'operator'),
          ),
          isSuperAdminProvider.overrideWithValue(false),
          currentPermissionsProvider.overrideWithValue({
            Perm.subcontractOrderView,
            Perm.subcontractOrderCreate,
            Perm.subcontractReturnView,
            Perm.subcontractMaterialReturnView,
            Perm.subcontractMaterialReturnCreate,
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.byKey(const Key('draft-workspace-create')));
    await tester.pumpAndSettle();
    expect(find.text('创建新委外单'), findsOneWidget);
    expect(find.text('从在外结存登记余料'), findsOneWidget);
    expect(find.text('从回厂来源登记退回'), findsNothing);
    await tester.tap(find.text('从在外结存登记余料'));
    await tester.pumpAndSettle();
    expect(find.text('余料来源登记页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
