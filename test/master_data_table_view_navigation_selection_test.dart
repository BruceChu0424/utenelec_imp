import 'package:flutter/material.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _TablePage extends StatefulWidget {
  const _TablePage({super.key, this.multi = true, this.customClear = false});

  final bool multi;
  final bool customClear;

  @override
  State<_TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<_TablePage> {
  Set<String> selected = {};
  String? activeRow;
  int clears = 0;
  bool locked = false;
  final note = TextEditingController(text: 'unsaved draft');
  final rows = List.generate(1000, (i) => 'row-$i');

  void rebuild() => setState(() {});

  void seedAll() => setState(() => selected = rows.toSet());

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextField(key: const Key('draft-note'), controller: note),
        Expanded(
          child: MasterDataTableView<String>(
            virtualized: true,
            columns: [
              MasterColumnDef(
                key: 'name',
                label: 'Name',
                width: 220,
                value: (row) => row,
              ),
            ],
            items: rows,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            selectable: widget.multi,
            idOf: (row) => row,
            selectedIds: selected,
            onSelectedIdsChanged: locked
                ? null
                : (ids) => setState(() => selected = ids),
            onClearSelection: widget.customClear
                ? () {
                    if (locked) return;
                    clears++;
                    setState(selected.clear);
                  }
                : null,
            onSelectionChanged: (row) => setState(() => activeRow = row),
            onSelectionCleared: () {
              clears++;
              setState(() => activeRow = null);
            },
            onRowTap: (_) => context.push('/detail'),
          ),
        ),
      ],
    ),
  );
}

GoRouter _router(Widget page) => GoRouter(
  initialLocation: '/list',
  routes: [
    GoRoute(path: '/list', builder: (_, _) => page),
    GoRoute(
      path: '/detail',
      builder: (_, _) => const Scaffold(body: Text('detail')),
    ),
  ],
);

Future<void> _visitDetail(WidgetTester tester, GoRouter router) async {
  router.push<void>('/detail');
  await tester.pumpAndSettle();
  router.pop();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a new visit cannot reuse the previous visit first click as a double click',
    (tester) async {
      await withClock(Clock.fixed(DateTime(2026, 11, 3)), () async {
        final key = GlobalKey<_TablePageState>();
        final router = _router(_TablePage(key: key));
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        await tester.tap(find.text('row-0'));
        await tester.pump();
        expect(key.currentState!.selected, {'row-0'});
        await _visitDetail(tester, router);
        expect(key.currentState!.selected, isEmpty);
        await tester.tap(find.text('row-0'));
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/list');
        expect(key.currentState!.selected, {'row-0'});
      });
    },
  );
  for (final customClear in [false, true]) {
    testWidgets(
      'page return clears all 1000 targets using owner clear=$customClear and keeps unsaved input',
      (tester) async {
        final key = GlobalKey<_TablePageState>();
        final router = _router(_TablePage(key: key, customClear: customClear));
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        final page = key.currentState!;
        final table = tester.state(find.byType(MasterDataTableView<String>));
        await tester.enterText(find.byKey(const Key('draft-note')), '保留未保存输入');
        for (var visit = 0; visit < 12; visit++) {
          page.seedAll();
          await tester.pump();
          expect(page.selected.length, 1000);
          await _visitDetail(tester, router);
          expect(key.currentState, same(page));
          expect(
            tester.state(find.byType(MasterDataTableView<String>)),
            same(table),
          );
          expect(page.selected, isEmpty);
          expect(page.note.text, '保留未保存输入');
          expect(page.rows.length, 1000);
          expect(tester.takeException(), isNull);
        }
        expect(page.clears, customClear ? 12 : 0);
      },
    );
  }

  testWidgets(
    'dialog, rebuild and query-only navigation keep current selection',
    (tester) async {
      final key = GlobalKey<_TablePageState>();
      final router = _router(_TablePage(key: key));
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      await tester.tap(find.text('row-0'));
      await tester.pumpAndSettle();
      expect(key.currentState!.selected, {'row-0'});
      key.currentState!.rebuild();
      router.refresh();
      router.go('/list?sort=name');
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.byType(MasterDataTableView<String>)),
        builder: (_) => const AlertDialog(content: Text('temporary dialog')),
      );
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(key.currentState!.selected, {'row-0'});
      await _visitDetail(tester, router);
      expect(key.currentState!.selected, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('single row and owner action state clear on page return', (
    tester,
  ) async {
    final key = GlobalKey<_TablePageState>();
    final router = _router(_TablePage(key: key, multi: false));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('row-0'));
    await tester.pumpAndSettle();
    expect(key.currentState!.activeRow, 'row-0');
    await _visitDetail(tester, router);
    expect(key.currentState!.activeRow, isNull);
    expect(key.currentState!.clears, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching retained shell tabs clears the old table on return', (
    tester,
  ) async {
    final key = GlobalKey<_TablePageState>();
    late StatefulNavigationShell tabs;
    final router = GoRouter(
      initialLocation: '/list',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, shell) {
            tabs = shell;
            return shell;
          },
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/list',
                  builder: (_, _) => _TablePage(key: key),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/other',
                  builder: (_, _) => const Scaffold(body: Text('other tab')),
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final page = key.currentState!;
    page.seedAll();
    await tester.pump();
    tabs.goBranch(1);
    await tester.pumpAndSettle();
    expect(page.selected.length, 1000);
    tabs.goBranch(0);
    await tester.pumpAndSettle();
    expect(key.currentState, same(page));
    expect(page.selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an owner lock keeps a pending operation snapshot unchanged', (
    tester,
  ) async {
    final key = GlobalKey<_TablePageState>();
    final router = _router(_TablePage(key: key, customClear: true));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    key.currentState!
      ..seedAll()
      ..locked = true
      ..rebuild();
    await tester.pump();
    await _visitDetail(tester, router);
    expect(key.currentState!.selected.length, 1000);
    expect(key.currentState!.clears, 0);
    key.currentState!
      ..locked = false
      ..rebuild();
    await tester.pump();
    await _visitDetail(tester, router);
    expect(key.currentState!.selected, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
