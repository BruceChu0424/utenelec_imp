// 「返回即刷新」按数据变没变(ADR-108 / perf-frontend-04):
//   · 列表 → 详情(只查看) → 返回: 0 次重拉;
//   · 列表 → 详情(保存成功, 写修订号前进) → 返回: 恰好 1 次, 且发生在返回转场走完之后;
//   · 保存时发出的精准刷新(refreshKeys)在列表被盖住时只记下, 返回时合并成那 1 次;
//   · 超过 30 秒的旧数据, 纯查看返回也重拉;
//   · Web/桌面转场是约 150ms 的纯淡入淡出。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_transition_tracker.dart';
import 'package:uten_imp/core/theme/uten_page_transitions.dart';
import 'package:uten_imp/shared/providers/list_refresh_provider.dart';

const _listKey = 'test-docs';

class _ListPage extends ConsumerWidget {
  const _ListPage(this.onRefresh);

  final void Function(bool transitionIdle) onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.onPageResume(
      '/list',
      () => onRefresh(RouteTransitionTracker.instance.isIdle),
      refreshKeys: const [_listKey],
    );
    return Scaffold(
      body: TextButton(
        onPressed: () => context.push('/detail'),
        child: const Text('打开详情'),
      ),
    );
  }
}

class _DetailPage extends ConsumerWidget {
  const _DetailPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Column(
      children: [
        TextButton(
          // 保存成功: 网络层推进写修订号 + 页面发出本类单据的精准刷新。
          onPressed: () {
            ref.read(dataWriteRevisionProvider.notifier).state++;
            bumpListRefresh(ref, _listKey);
          },
          child: const Text('保存'),
        ),
        TextButton(onPressed: () => context.pop(), child: const Text('返回')),
      ],
    ),
  );
}

Future<(List<bool>, ProviderContainer)> _pump(WidgetTester tester) async {
  RouteTransitionTracker.instance.reset();
  final refreshes = <bool>[];
  final router = GoRouter(
    initialLocation: '/list',
    routes: [
      GoRoute(path: '/list', builder: (_, _) => _ListPage(refreshes.add)),
      GoRoute(path: '/detail', builder: (_, _) => const _DetailPage()),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  addTearDown(
    attachPageResume(router, container.read(pageResumeProvider.notifier)),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(pageTransitionsTheme: utenPageTransitionsTheme()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (refreshes, container);
}

void main() {
  testWidgets('view-only return does not reload the list', (tester) async {
    final (refreshes, _) = await _pump(tester);

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    expect(refreshes, isEmpty);
  });

  testWidgets(
    'save then return reloads exactly once, after the transition settles',
    (tester) async {
      final (refreshes, _) = await _pump(tester);

      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      // 列表被详情盖着: 精准刷新只记下, 不在后台重拉。
      expect(refreshes, isEmpty);

      await tester.tap(find.text('返回'));
      await tester.pump(); // 转场刚开始
      await tester.pump(const Duration(milliseconds: 60));
      expect(refreshes, isEmpty, reason: '转场期间不重拉');
      await tester.pumpAndSettle();

      expect(refreshes, [true], reason: '恰好一次, 且在转场静止之后');
    },
  );

  testWidgets('stale data (>30s) reloads on a view-only return', (
    tester,
  ) async {
    final (refreshes, _) = await _pump(tester);

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 31));
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    expect(refreshes, hasLength(1));
  });

  testWidgets('precise refresh while the list is on top reloads at once', (
    tester,
  ) async {
    final (refreshes, container) = await _pump(tester);

    container.read(listRefreshTickProvider(_listKey).notifier).state++;
    await tester.pumpAndSettle();

    expect(refreshes, hasLength(1));
  });

  test(
    'web and desktop use a ~150ms fade; mobile keeps the platform default',
    () {
      const builder = UtenFadePageTransitionsBuilder();
      expect(builder.transitionDuration, const Duration(milliseconds: 150));
      expect(usesLightweightPageTransitions(isWeb: true), isTrue);
      expect(
        usesLightweightPageTransitions(
          isWeb: false,
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
      expect(
        usesLightweightPageTransitions(
          isWeb: false,
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
    },
  );
}
