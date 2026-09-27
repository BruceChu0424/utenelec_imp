import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';

void main() {
  Future<GoRouter> pumpRouter(
    WidgetTester tester, {
    String initial = '/drafts?status=draft',
    bool nestedDetail = false,
  }) async {
    Widget page(String name, {String? saveTo}) => Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            Text(name),
            if (saveTo != null)
              TextButton(
                onPressed: () => popSavedEditOrReplace(context, saveTo),
                child: const Text('保存'),
              ),
            TextButton(
              onPressed: () => backTo(context, defaultPath: '/hub'),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );

    final router = GoRouter(
      initialLocation: initial,
      routes: [
        ShellRoute(
          builder: (_, _, child) => child,
          routes: [
            GoRoute(path: '/hub', builder: (_, _) => page('管理页')),
            GoRoute(path: '/drafts', builder: (_, _) => page('草稿列表')),
            GoRoute(
              path: '/docs/:id',
              builder: (_, state) => page('审核 ${state.pathParameters['id']}'),
              routes: [
                if (nestedDetail)
                  GoRoute(
                    path: 'edit',
                    builder: (_, state) => page(
                      '编辑',
                      saveTo: '/docs/${state.pathParameters['id']}',
                    ),
                  ),
              ],
            ),
            if (!nestedDetail)
              GoRoute(
                path: '/docs/:id/edit',
                builder: (_, state) =>
                    page('编辑', saveTo: '/docs/${state.pathParameters['id']}'),
              ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('草稿列表直接编辑，保存进入审核且一次返回原筛选列表', (tester) async {
    final router = await pumpRouter(tester);
    router.push<void>('/docs/one/edit');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('审核 one'), findsOneWidget);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('草稿列表'), findsOneWidget);
    expect(router.state.uri.toString(), '/drafts?status=draft');
  });

  testWidgets('同单审核详情进入编辑，保存pop复用宿主且不叠详情', (tester) async {
    final router = await pumpRouter(tester);
    router.push<void>('/docs/one?returnTo=/drafts');
    await tester.pumpAndSettle();
    final detailKey = router.routerDelegate.currentConfiguration.last.pageKey;
    var editReturned = false;
    router.push<void>('/docs/one/edit').then((_) => editReturned = true);
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('审核 one'), findsOneWidget);
    expect(editReturned, isTrue);
    expect(router.routerDelegate.currentConfiguration.last.pageKey, detailKey);
    expect(router.state.uri.queryParameters['returnTo'], '/drafts');

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('草稿列表'), findsOneWidget);
  });

  testWidgets('另一张单的详情进入编辑，保存不能pop回错误单据', (tester) async {
    final router = await pumpRouter(tester);
    router.push<void>('/docs/other');
    await tester.pumpAndSettle();
    router.push<void>('/docs/one/edit');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('审核 one'), findsOneWidget);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('审核 other'), findsOneWidget);
  });

  testWidgets('深链编辑保存后继承returnTo，审核页可回草稿筛选列表', (tester) async {
    final router = await pumpRouter(
      tester,
      initial: '/docs/one/edit?returnTo=%2Fdrafts%3Fstatus%3Ddraft',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('审核 one'), findsOneWidget);
    expect(
      router.state.uri.queryParameters['returnTo'],
      '/drafts?status=draft',
    );

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('草稿列表'), findsOneWidget);
    expect(router.state.uri.toString(), '/drafts?status=draft');
  });

  testWidgets('嵌套声明的编辑路由仍识别同单详情父页', (tester) async {
    final router = await pumpRouter(
      tester,
      initial: '/docs/one/edit',
      nestedDetail: true,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('审核 one'), findsOneWidget);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
