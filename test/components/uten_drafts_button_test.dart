// 「草稿(N)」入口按钮：计数文案、权限显隐、跳转落点（列表 + ?status=draft）。
//
// 背景：管理卡 skipListOnCreate 直达新建页后，列表从 hub 不可达；本按钮是用户
// 回到自己草稿的唯一入口，三条行为都必须锁死。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_drafts_button.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';

/// 被按钮导航到的路径（含 query）。
String? _navigatedTo;

Widget _app({
  required Set<String> permissions,
  required DraftCounts counts,
  DraftDocKind kind = DraftDocKind.salesOrder,
  String listLocation = '/sales/orders',
  String? countScopeNote,
}) {
  final router = GoRouter(
    initialLocation: '/sales/orders/new',
    routes: [
      GoRoute(
        path: '/sales/orders/new',
        builder: (_, _) => Scaffold(
          appBar: AppBar(
            actions: [
              UtenDraftsButton(
                kind: kind,
                listLocation: listLocation,
                countScopeNote: countScopeNote,
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: '/sales/orders',
        builder: (context, state) {
          _navigatedTo = state.uri.toString();
          return const Scaffold(body: Text('列表'));
        },
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      currentPermissionsProvider.overrideWithValue(permissions),
      isSuperAdminProvider.overrideWithValue(false),
      draftCountsProvider.overrideWith((ref) async => counts),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUp(() => _navigatedTo = null);

  testWidgets('计数 > 0 时「草稿」后面挂红底白字徽章（2026-09-11 起不再是括号数字）', (tester) async {
    await tester.pumpWidget(
      _app(
        permissions: const {Perm.salesOrderView},
        counts: const DraftCounts(salesOrder: 3),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('草稿'), findsOneWidget);
    expect(find.text('草稿(3)'), findsNothing);
    // 数字由 UtenNotificationBadge 画，文案与计数是两个 Text。
    final badge = tester.widget<UtenNotificationBadge>(
      find.descendant(
        of: find.byKey(const Key('uten-drafts-button')),
        matching: find.byType(UtenNotificationBadge),
      ),
    );
    expect(badge.count, 3);
    expect(find.text('3'), findsOneWidget);
    expect(find.byKey(const Key('uten-drafts-button')), findsOneWidget);
  });

  testWidgets('计数为 0 时只显示「草稿」，徽章整个不渲染', (tester) async {
    await tester.pumpWidget(
      _app(permissions: const {Perm.salesOrderView}, counts: DraftCounts.empty),
    );
    await tester.pumpAndSettle();

    expect(find.text('草稿'), findsOneWidget);
    expect(find.text('草稿(0)'), findsNothing);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('无该单据 view 权限时整个按钮隐藏', (tester) async {
    await tester.pumpWidget(
      _app(
        permissions: const {Perm.salesShipmentView}, // 有出货没有订货
        counts: const DraftCounts(salesOrder: 3),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('uten-drafts-button')), findsNothing);
    expect(find.textContaining('草稿'), findsNothing);
  });

  testWidgets('点击跳到列表并带 ?status=draft 预选草稿段', (tester) async {
    await tester.pumpWidget(
      _app(
        permissions: const {Perm.salesOrderView},
        counts: const DraftCounts(salesOrder: 2),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('uten-drafts-button')));
    await tester.pumpAndSettle();

    expect(_navigatedTo, isNotNull);
    final uri = Uri.parse(_navigatedTo!);
    expect(uri.path, '/sales/orders');
    expect(uri.queryParameters['status'], 'draft');
    // goFrom 同时带来源，列表页返回能回到新建页。
    expect(uri.queryParameters['returnTo'], '/sales/orders/new');
  });

  testWidgets('countScopeNote 出现在 tooltip 里（仓库单据合计口径）', (tester) async {
    await tester.pumpWidget(
      _app(
        permissions: const {Perm.stockDocView},
        counts: const DraftCounts(stockDocument: 5),
        kind: DraftDocKind.stockDocument,
        listLocation: '/warehouse/OTHER_IN',
        countScopeNote: '全部仓库单据合计',
      ),
    );
    await tester.pumpAndSettle();

    // 2026-09-11 起按钮收敛为 UtenAppBarActionButton（key 挂在它身上），
    // Tooltip 在其内部，故按后代查而不是祖先。
    final tooltip = tester.widget<Tooltip>(
      find.descendant(
        of: find.byKey(const Key('uten-drafts-button')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, contains('5'));
    expect(tooltip.message, contains('全部仓库单据合计'));
  });
}
