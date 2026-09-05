import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/shared/auth/page_permission_action.dart';

// go_router 14.8 无限重挂载回归锁（2026-09-04 整站卡死事故）：
// 命令式 MaterialPageRoute 推出的子页里，UtenAppBar 默认携带的
// PagePermissionAction 曾在 build 期调 GoRouterState.of 向上爬到宿主路由，
// 并在 LayoutBuilder 布局期对 GoRouterStateRegistry（InheritedNotifier）
// 建立跨路由依赖，触发无限重挂载循环（真机点开分桶详情即整站卡死，
// 栈 600+ 层直至进程死亡）。修复契约：非 go_router 页路由一律 fail-closed，
// 不解析 scope、不建立任何跨路由 inherited 依赖。
void main() {
  testWidgets('PagePermissionAction stays inert inside a pushed route', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) =>
              const Scaffold(body: Center(child: _PushSubPageButton())),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('push-sub-page')));
    // 有界 settle：循环复发时这里超时失败（回归锁钉死本事故）。
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 15),
    );

    expect(find.text('子弹层页'), findsOneWidget);
    // 子弹层没有独立路由 scope：权限入口必须 fail-closed（不渲染按钮，
    // 也不抛异常、不建立跨路由依赖）。
    expect(find.byKey(const ValueKey('page-permission-action')), findsNothing);
    expect(find.byType(PagePermissionAction), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _PushSubPageButton extends StatelessWidget {
  const _PushSubPageButton();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: const Key('push-sub-page'),
      onPressed: () => Navigator.of(
        context,
      ).push<void>(MaterialPageRoute(builder: _PushSubPageButton.buildSubPage)),
      child: const Text('推入子页'),
    );
  }

  static Widget buildSubPage(BuildContext context) {
    return const Scaffold(body: _SubPageBody());
  }

  static Widget expandBody(BuildContext context, BoxConstraints constraints) {
    return const SizedBox.expand();
  }
}

class _SubPageBody extends StatelessWidget {
  const _SubPageBody();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        _SubPageAppBar(),
        Expanded(child: LayoutBuilder(builder: _PushSubPageButton.expandBody)),
      ],
    );
  }
}

class _SubPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SubPageAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    // ignore: prefer_const_constructors UtenAppBar 构造非 const（含可选回调）
    return UtenAppBar(title: '子弹层页');
  }
}
