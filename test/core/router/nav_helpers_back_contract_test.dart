// 返回键契约（docs/05-架构/路由设计.md §十一，2026-09-10 收敛）：
//  1. 被 push 进入的页面用 backTo 返回 → pop 回上一页（栈下页保留）；
//  2. 栈空（go 直达）且带 ?returnTo → go 回来源；
//  3. 栈空且无 returnTo → go 到 defaultPath。
// 此前 backTo 永远 context.go，push 进来的三四层页面一按返回就跳回 hub/工作台。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';

class _Page extends StatelessWidget {
  const _Page(this.name);
  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('page:$name'),
        TextButton(
          key: Key('back-$name'),
          onPressed: () => backTo(context, defaultPath: '/hub'),
          child: const Text('back'),
        ),
        TextButton(
          key: Key('push-b-from-$name'),
          onPressed: () => context.push('/b'),
          child: const Text('push b'),
        ),
        const UtenBackButton(),
      ],
    ),
  );
}

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: [
    ShellRoute(
      builder: (_, _, child) => child,
      routes: [
        GoRoute(path: '/hub', builder: (_, _) => const _Page('hub')),
        GoRoute(path: '/dashboard', builder: (_, _) => const _Page('dash')),
        GoRoute(path: '/a', builder: (_, _) => const _Page('a')),
        GoRoute(path: '/b', builder: (_, _) => const _Page('b')),
      ],
    ),
  ],
);

void main() {
  testWidgets('backTo pops when the page was pushed', (tester) async {
    final router = _router('/a');
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('push-b-from-a')));
    await tester.pumpAndSettle();
    expect(find.text('page:b'), findsOneWidget);

    await tester.tap(find.byKey(const Key('back-b')));
    await tester.pumpAndSettle();
    expect(find.text('page:a'), findsOneWidget, reason: 'pop 回上一页而非 hub');
    expect(find.text('page:hub'), findsNothing);
  });

  testWidgets('backTo reads returnTo when the stack is empty', (tester) async {
    final router = _router('/b?returnTo=/a');
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('back-b')));
    await tester.pumpAndSettle();
    expect(find.text('page:a'), findsOneWidget);
  });

  testWidgets('backTo falls back to defaultPath', (tester) async {
    final router = _router('/b');
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('back-b')));
    await tester.pumpAndSettle();
    expect(find.text('page:hub'), findsOneWidget);
  });

  testWidgets('UtenBackButton default delegates to backTo (pop first)', (
    tester,
  ) async {
    final router = _router('/a');
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('push-b-from-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(UtenBackButton).last);
    await tester.pumpAndSettle();
    expect(find.text('page:a'), findsOneWidget);
  });
}
