import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/page_navigation_session.dart';

class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final navigation = PageNavigationSession();
  bool opening = false;
  int returns = 0;
  Object? result;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    navigation.attach(context);
  }

  @override
  void dispose() {
    navigation.dispose();
    super.dispose();
  }

  Future<void> open<T extends Object?>([String path = '/detail']) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      final value = await navigation.push<T>(path);
      if (!mounted) return;
      setState(() {
        returns++;
        result = value;
      });
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text(opening ? 'locked' : 'ready'),
        TextButton(onPressed: () => open<String>(), child: const Text('open')),
      ],
    ),
  );
}

Future<(GoRouter, GlobalKey<_HostState>)> _pump(
  WidgetTester tester, {
  bool shell = false,
  bool Function()? allowExit,
}) async {
  final host = GlobalKey<_HostState>();
  final routes = <RouteBase>[
    GoRoute(
      path: '/source',
      builder: (_, _) => _Host(key: host),
    ),
    GoRoute(
      path: '/detail',
      onExit: (_, _) => allowExit?.call() ?? true,
      builder: (_, _) => const Scaffold(body: Text('detail')),
    ),
    GoRoute(
      path: '/replacement',
      builder: (_, _) => const Scaffold(body: Text('replacement')),
    ),
    GoRoute(
      path: '/child',
      builder: (_, _) => const Scaffold(body: Text('child')),
    ),
    GoRoute(
      path: '/away',
      builder: (_, _) => const Scaffold(body: Text('away')),
    ),
  ];
  final router = GoRouter(
    initialLocation: '/source',
    routes: shell
        ? [ShellRoute(builder: (_, _, child) => child, routes: routes)]
        : routes,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return (router, host);
}

Future<void> _browserGo(GoRouter router, String location) => router
    .routeInformationProvider
    .didPushRouteInformation(RouteInformation(uri: Uri.parse(location)));

void main() {
  for (final shell in [false, true]) {
    for (final mode in ['pop', 'go', 'browser']) {
      testWidgets('$mode returns release only their visit, shell=$shell', (
        tester,
      ) async {
        final (router, key) = await _pump(tester, shell: shell);
        final owner = key.currentState!;
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final oldVisit =
            router.routerDelegate.currentConfiguration.last
                as ImperativeRouteMatch;
        expect(owner.opening, isTrue);
        switch (mode) {
          case 'pop':
            router.pop('saved-id');
          case 'go':
            router.go('/source');
          case 'browser':
            await _browserGo(router, '/source');
        }
        await tester.pumpAndSettle();
        expect(key.currentState, same(owner));
        expect(owner.opening, isFalse);
        expect(owner.returns, 1);
        expect(owner.result, mode == 'pop' ? 'saved-id' : isNull);
        expect(owner.navigation.consumeReturnedVisit(), isTrue);
        expect(owner.navigation.consumeReturnedVisit(), isFalse);

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        if (!oldVisit.completer.isCompleted) oldVisit.complete('late-id');
        await tester.pumpAndSettle();
        expect(owner.opening, isTrue);
        expect(owner.returns, 1);
        router.pop('second-id');
        await tester.pumpAndSettle();
        expect(owner.result, 'second-id');
        expect(owner.returns, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final replace in [false, true]) {
    testWidgets('replacement chain stays owned until source return: $replace', (
      tester,
    ) async {
      final (router, key) = await _pump(tester);
      final owner = key.currentState!;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (replace) {
        router.replace<void>('/replacement');
      } else {
        router.pushReplacement<void>('/replacement');
      }
      await tester.pumpAndSettle();
      expect(find.text('replacement'), findsOneWidget);
      expect(owner.opening, isTrue);
      expect(owner.returns, 0);
      router.pop();
      await tester.pumpAndSettle();
      expect(owner.opening, isFalse);
      expect(owner.returns, 1);
      expect(owner.result, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('covering a child visit does not finish it; bool pop survives', (
    tester,
  ) async {
    final (router, key) = await _pump(tester);
    final owner = key.currentState!;
    owner.open<bool>();
    await tester.pumpAndSettle();
    router.push<void>('/child');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(owner.opening, isTrue);
    expect(owner.returns, 0);
    router.pop(true);
    await tester.pumpAndSettle();
    expect(owner.result, isTrue);
    expect(owner.returns, 1);
  });

  testWidgets('a refused exit leaves the visit and guard intact', (
    tester,
  ) async {
    var allow = false;
    final (router, key) = await _pump(tester, allowExit: () => allow);
    final owner = key.currentState!;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await _browserGo(router, '/source');
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);
    expect(owner.opening, isTrue);
    expect(owner.returns, 0);
    allow = true;
    await _browserGo(router, '/source');
    await tester.pumpAndSettle();
    expect(owner.opening, isFalse);
    expect(owner.result, isNull);
  });

  testWidgets('owner removal disposes the visit without updating dead State', (
    tester,
  ) async {
    final (router, key) = await _pump(tester);
    final owner = key.currentState!;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    router.go('/away');
    await tester.pumpAndSettle();
    expect(owner.mounted, isFalse);
    expect(owner.returns, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'browser forward/restoration does not mutate old router Futures',
    (tester) async {
      final (router, key) = await _pump(tester);
      final owner = key.currentState!;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final saved = router.routerDelegate.currentConfiguration;
      final original = saved.last as ImperativeRouteMatch;
      await _browserGo(router, '/source');
      await tester.pumpAndSettle();
      expect(owner.returns, 1);
      expect(original.completer.isCompleted, isFalse);
      router.restore(saved);
      await tester.pumpAndSettle();
      router.pop('restored-result');
      await tester.pumpAndSettle();
      expect(original.completer.isCompleted, isTrue);
      expect(owner.returns, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a later ordinary link still owns its independent return refresh',
    (tester) async {
      final (router, key) = await _pump(tester);
      final owner = key.currentState!;
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      router.pop('id');
      await tester.pumpAndSettle();
      // Even if no resume provider consumes this marker, it cannot survive a
      // different departure and suppress that link's future revalidation.
      router.push<void>('/detail');
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(owner.navigation.consumeReturnedVisit(), isFalse);
      expect(owner.returns, 1);
    },
  );
}
