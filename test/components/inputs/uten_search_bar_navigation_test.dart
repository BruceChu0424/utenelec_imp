import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/router/page_search_lifecycle.dart';

class _SearchPage extends StatefulWidget {
  const _SearchPage({
    super.key,
    required this.changes,
    this.inputs,
    this.initialValue = '',
    this.submitOnly = false,
    this.controller,
  });

  final List<String> changes;
  final List<String>? inputs;
  final String initialValue;
  final bool submitOnly;
  final TextEditingController? controller;

  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  late String query = widget.initialValue;
  int searchGeneration = 0;

  void rebuild() => setState(() {});
  void remountSearch() => setState(() => searchGeneration++);

  void _search(String value) {
    widget.changes.add(value);
    setState(() => query = value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        UtenSearchBar(
          key: ValueKey(searchGeneration),
          controller: widget.controller,
          initialValue: query,
          debounce: const Duration(milliseconds: 100),
          onInputChanged: widget.inputs?.add,
          onChanged: widget.submitOnly ? null : _search,
          onSubmitted: widget.submitOnly ? _search : null,
        ),
        Text('applied:$query'),
      ],
    ),
  );
}

GoRouter _router(Widget page) => GoRouter(
  initialLocation: '/list?search=linked',
  routes: [
    GoRoute(path: '/list', builder: (_, _) => page),
    GoRoute(
      path: '/detail',
      builder: (_, _) => const Scaffold(body: Text('detail')),
    ),
  ],
);

class _FullscreenSearchHost extends StatefulWidget {
  const _FullscreenSearchHost({required this.changes});

  final List<String> changes;

  @override
  State<_FullscreenSearchHost> createState() => _FullscreenSearchHostState();
}

class _FullscreenSearchHostState extends State<_FullscreenSearchHost> {
  late final lifecycle = PageSearchLifecycle(onLeave: () {}, onReturn: () {});

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    lifecycle.attach(context);
  }

  @override
  void dispose() {
    lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => lifecycle.wrap(
          AlertDialog(
            content: UtenSearchBar(
              initialValue: 'fullscreen search',
              onChanged: widget.changes.add,
            ),
          ),
        ),
      ),
      child: const Text('fullscreen'),
    ),
  );
}

void main() {
  testWidgets('returning with an empty search emits no redundant query', (
    tester,
  ) async {
    final changes = <String>[];
    final inputs = <String>[];
    final router = _router(_SearchPage(changes: changes, inputs: inputs));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.push<void>('/detail');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(inputs, isEmpty);
  });

  testWidgets(
    'return clears an applied query when its deletion was debounced',
    (tester) async {
      final changes = <String>[];
      final router = _router(
        _SearchPage(changes: changes, initialValue: 'applied'),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      router.push<void>('/detail');
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      router.pop();
      await tester.pumpAndSettle();
      expect(changes, ['']);
      expect(find.text('applied:'), findsOneWidget);
    },
  );

  testWidgets('push and pop clear applied query and both search callbacks once', (
    tester,
  ) async {
    final changes = <String>[];
    final inputs = <String>[];
    final key = GlobalKey<_SearchPageState>();
    final router = _router(
      _SearchPage(
        key: key,
        initialValue: 'linked',
        changes: changes,
        inputs: inputs,
      ),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('applied:linked'), findsOneWidget);
    expect(changes, isEmpty);

    // Rebuilds, refresh notifications and query-only navigation keep the session.
    key.currentState!.rebuild();
    router.refresh();
    await tester.pumpAndSettle();
    router.go('/list?search=linked&sort=name');
    await tester.pumpAndSettle();
    expect(find.text('linked'), findsOneWidget);
    expect(changes, isEmpty);

    router.push<void>('/detail');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('applied:'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    expect(changes, ['']);
    expect(inputs, ['']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'navigation cancels a pending query before it can apply offstage',
    (tester) async {
      final changes = <String>[];
      final inputs = <String>[];
      final router = _router(_SearchPage(changes: changes, inputs: inputs));
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'stale');
      expect(inputs, ['stale']);
      router.push<void>('/detail');
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      router.pop();
      await tester.pumpAndSettle();
      expect(changes, ['']);
      expect(inputs, ['stale', '']);
      await tester.pump(const Duration(milliseconds: 300));
      expect(changes, ['']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('search remounted below pushed detail still resets on return', (
    tester,
  ) async {
    final changes = <String>[];
    final key = GlobalKey<_SearchPageState>();
    final router = _router(
      _SearchPage(key: key, changes: changes, initialValue: 'old session'),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    router.push<void>('/detail');
    await tester.pumpAndSettle();
    key.currentState!.remountSearch();
    await tester.pump();
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('applied:'), findsOneWidget);
    expect(changes, ['']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('return cancels held IME composition and clears external text', (
    tester,
  ) async {
    final changes = <String>[];
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final router = _router(
      _SearchPage(changes: changes, controller: controller),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'li',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    router.push<void>('/detail');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(controller.text, '');
    expect(controller.value.composing, TextRange.empty);
    expect(changes, ['']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('submit-only query is cleared even after its input was erased', (
    tester,
  ) async {
    final changes = <String>[];
    final router = _router(_SearchPage(changes: changes, submitOnly: true));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'submitted');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('applied:submitted'), findsOneWidget);
    router.push<void>('/detail');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('applied:'), findsOneWidget);
    expect(changes, ['submitted', '']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dialogs and fullscreen Navigator routes preserve host query', (
    tester,
  ) async {
    final changes = <String>[];
    final key = GlobalKey<_SearchPageState>();
    final router = _router(
      _SearchPage(key: key, changes: changes, initialValue: 'keep'),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    showDialog<void>(
      context: key.currentContext!,
      builder: (_) => const AlertDialog(content: UtenSearchBar()),
    );
    await tester.pumpAndSettle();
    Navigator.of(key.currentContext!, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    Navigator.of(key.currentContext!).push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: UtenSearchBar())),
    );
    await tester.pumpAndSettle();
    Navigator.of(key.currentContext!).pop();
    await tester.pumpAndSettle();
    expect(find.text('applied:keep'), findsOneWidget);
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('kept-alive shell search clears after go away and go back', (
    tester,
  ) async {
    final changes = <String>[];
    final key = GlobalKey<_SearchPageState>();
    final page = _SearchPage(key: key, changes: changes, initialValue: 'keep');
    final router = GoRouter(
      initialLocation: '/list',
      routes: [
        ShellRoute(
          builder: (_, state, child) => Stack(
            children: [
              Offstage(
                offstage: state.uri.path != '/list',
                child: PageSearchRouteScope(location: '/list', child: page),
              ),
              if (state.uri.path != '/list') child,
            ],
          ),
          routes: [
            GoRoute(path: '/list', builder: (_, _) => const SizedBox()),
            GoRoute(
              path: '/other',
              builder: (_, _) => const Scaffold(body: Text('other')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final originalState = key.currentState;
    router.go('/other');
    await tester.pumpAndSettle();
    // A dependency update while hidden must not capture the other page identity.
    key.currentState!.rebuild();
    await tester.pump();
    router.go('/list');
    await tester.pumpAndSettle();
    expect(key.currentState, same(originalState));
    expect(find.text('applied:'), findsOneWidget);
    expect(changes, ['']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search first mounted in fullscreen uses explicit host session', (
    tester,
  ) async {
    final changes = <String>[];
    final router = _router(_FullscreenSearchHost(changes: changes));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('fullscreen'));
    await tester.pumpAndSettle();
    expect(find.text('fullscreen search'), findsOneWidget);
    expect(changes, isEmpty);
    router.push<void>('/detail');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(changes, ['']);
    expect(find.text('fullscreen search'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('parameter route reused with a new path starts a fresh search', (
    tester,
  ) async {
    final changes = <String>[];
    final key = GlobalKey<_SearchPageState>();
    final page = _SearchPage(key: key, changes: changes, initialValue: 'old');
    final router = GoRouter(
      initialLocation: '/list/detail',
      routes: [GoRoute(path: '/list/:section', builder: (_, _) => page)],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final originalState = key.currentState;
    router.go('/list/summary');
    await tester.pumpAndSettle();
    expect(key.currentState, same(originalState));
    expect(find.text('applied:'), findsOneWidget);
    expect(changes, ['']);
    await tester.enterText(find.byType(TextField), 'next session');
    await tester.pump(const Duration(milliseconds: 150));
    router.go('/list/detail');
    await tester.pumpAndSettle();
    expect(changes, ['', 'next session', '']);
    expect(find.text('applied:'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unmount cancels queued return callbacks and debounced work', (
    tester,
  ) async {
    final changes = <String>[];
    final router = _router(_SearchPage(changes: changes));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'stale');
    router.push<void>('/detail');
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    expect(changes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
