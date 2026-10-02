import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_paged_picker_list.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _pageSize = 14;

List<String> _rowsFor(String scope, int page) => [
  for (var row = 0; row < _pageSize; row++) '$scope-page-$page-row-$row',
];

String _id(String row) => row;

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.primary = false,
    this.picker = false,
    this.withIdentity = true,
    this.variableHeight = false,
    this.zoom = 1,
    this.leadingContent = false,
    this.maxRetainedPages = 5,
    this.selectable = false,
  });

  final bool primary;
  final bool picker;
  final bool withIdentity;
  final bool variableHeight;
  final double zoom;
  final bool leadingContent;
  final int maxRetainedPages;
  final bool selectable;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final rows = MasterDataTableRowsController<String>();
  final primaryController = ScrollController();
  final requests = <int>[];
  Set<String> selectedIds = {};
  String scope = 'A';
  int page = 1;
  List<String> items = _rowsFor('A', 1);

  Future<void> load(int target) async {
    requests.add(target);
    setState(() {
      items = _rowsFor(scope, target);
      page = target;
    });
  }

  void resetQuery() => setState(() {
    scope = 'B';
    page = 1;
    items = _rowsFor(scope, page);
  });

  double _height(String row) {
    if (!widget.variableHeight) return 42;
    final index = int.tryParse(row.split('-').last) ?? 0;
    return 32 + (index % 4) * 27.0;
  }

  Widget _cell(String row) => SizedBox(
    key: ValueKey('anchor-$row'),
    height: _height(row),
    child: Align(alignment: Alignment.topLeft, child: Text(row)),
  );

  @override
  void dispose() {
    primaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.picker
        ? UtenPagedPickerList<String>(
            items: items,
            idOf: _id,
            itemBuilder: (_, row) => _cell(row),
            currentPage: page,
            totalPages: 5,
            onPageChange: load,
            paginationScope: scope,
            paginationRevision: items,
            rowsController: rows,
          )
        : MasterDataTableView<String>(
            columns: [
              MasterColumnDef<String>(
                key: 'value',
                label: '值',
                width: 400,
                value: _id,
                cellBuilder: (_, row) => _cell(row),
              ),
            ],
            items: items,
            unpagedItems: widget.leadingContent
                ? const ['local-draft']
                : const [],
            leadingGroups: widget.leadingContent
                ? const [
                    MasterDataGroup<String>(
                      id: 'disabled',
                      title: '前导分组',
                      items: ['group-record'],
                    ),
                  ]
                : null,
            rowsController: rows,
            rowKeyOf: widget.withIdentity ? _id : null,
            maxRetainedPages: widget.maxRetainedPages,
            selectable: widget.selectable,
            idOf: widget.selectable ? _id : null,
            selectedIds: selectedIds,
            onSelectedIdsChanged: widget.selectable
                ? (ids) => setState(() => selectedIds = ids)
                : null,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            currentPage: page,
            totalPages: 5,
            onPageChange: load,
            paginationScope: scope,
            paginationRevision: items,
            primary: widget.primary,
          );
    return MaterialApp(
      home: Scaffold(
        body: Transform.scale(
          scale: widget.zoom,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 700,
            height: 390,
            child: widget.primary
                ? PrimaryScrollController(
                    controller: primaryController,
                    child: body,
                  )
                : body,
          ),
        ),
      ),
    );
  }
}

ScrollableState _vertical(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .firstWhere((state) => state.position.axis == Axis.vertical);

Future<void> _wheel(WidgetTester tester, double dy) async {
  final scrollable = _vertical(tester);
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(tester.getCenter(find.byWidget(scrollable.widget))),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
  await tester.pumpAndSettle();
}

void _expectPage(WidgetTester tester, int page) {
  expect(find.widgetWithText(TextFormField, '$page'), findsOneWidget);
}

Future<void> _loadThreePages(WidgetTester tester, _HarnessState host) async {
  await host.rows.loadNextPage();
  await tester.pumpAndSettle();
  await host.rows.loadNextPage();
  await tester.pumpAndSettle();
  expect(host.requests, [2, 3]);
  expect(
    host.rows.items.where((row) => row.startsWith('A-page-')),
    hasLength(_pageSize * 3),
  );
  _expectPage(tester, 1);
}

Future<void> _lookAtPage(
  WidgetTester tester,
  int page, {
  required bool forward,
}) async {
  // Use a row within the page rather than its boundary: a partly visible final
  // row of the preceding page must not make the expected visible page ambiguous.
  final anchor = find.byKey(ValueKey('anchor-A-page-$page-row-2'));
  final scrollable = find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            axisDirectionToAxis(widget.axisDirection) == Axis.vertical,
      )
      .first;
  await tester.scrollUntilVisible(
    anchor,
    forward ? 180 : -180,
    scrollable: scrollable,
    maxScrolls: 60,
  );
  await Scrollable.ensureVisible(tester.element(anchor));
  await tester.pumpAndSettle();
  await _wheel(tester, 1);
}

void main() {
  testWidgets('focused page input survives scrolling until submit or blur', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _loadThreePages(tester, host);
    await _lookAtPage(tester, 2, forward: true);
    _expectPage(tester, 2);

    await tester.enterText(find.byType(TextFormField), '4');
    await _lookAtPage(tester, 1, forward: false);
    _expectPage(tester, 4);
    await _lookAtPage(tester, 2, forward: true);
    _expectPage(tester, 4);
    expect(host.requests, [
      2,
      3,
    ], reason: 'scrolling does not submit typed pages');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(host.requests, [2, 3, 4]);
    expect(host.rows.items, _rowsFor('A', 4));
    _expectPage(tester, 4);

    await tester.enterText(find.byType(TextFormField), '5');
    await _wheel(tester, 40);
    _expectPage(tester, 5);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    _expectPage(tester, 4);
    expect(host.requests, [
      2,
      3,
      4,
    ], reason: 'blurring an edit restores visible page');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'evicted selected snapshots do not participate in visible pages',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        _Harness(key: key, selectable: true, maxRetainedPages: 2),
      );
      await tester.pumpAndSettle();
      final host = key.currentState!;
      tester
          .widget<MasterDataTableView<String>>(
            find.byType(MasterDataTableView<String>),
          )
          .onSelectedIdsChanged!({'A-page-1-row-0'});
      await tester.pumpAndSettle();

      await host.rows.loadNextPage();
      await tester.pumpAndSettle();
      await _lookAtPage(tester, 2, forward: true);
      await host.rows.loadNextPage();
      await tester.pumpAndSettle();
      await _lookAtPage(tester, 3, forward: true);
      await host.rows.loadNextPage();
      await tester.pumpAndSettle();
      expect(host.requests, [2, 3, 4]);
      expect(host.page, 4);
      expect(host.selectedIds, {'A-page-1-row-0'});
      expect(host.rows.items, contains('A-page-1-row-0'));
      expect(
        host.rows.items.where((row) => row.startsWith('A-page-1-')),
        ['A-page-1-row-0'],
        reason: 'only the selected snapshot survives outside the page window',
      );
      expect(
        host.rows.items.where((row) => row.startsWith('A-page-2-')),
        isEmpty,
      );
      expect(find.byKey(const ValueKey('anchor-A-page-1-row-0')), findsNothing);
      await _lookAtPage(tester, 3, forward: false);
      _expectPage(tester, 3);

      await host.rows.loadPreviousPage();
      await tester.pumpAndSettle();
      expect(host.requests, [2, 3, 4, 2]);
      _expectPage(tester, 3);
      await _lookAtPage(tester, 2, forward: false);
      _expectPage(tester, 2);
      expect(host.requests, [2, 3, 4, 2]);
      expect(host.rows.items, contains('A-page-1-row-0'));
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in [
    'table',
    'values',
    'variable-zoom',
    'picker',
    'primary',
  ]) {
    testWidgets('$mode page indicator follows cached rows without fetching', (
      tester,
    ) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        _Harness(
          key: key,
          primary: mode == 'primary',
          picker: mode == 'picker',
          withIdentity: mode != 'values',
          variableHeight: mode == 'variable-zoom',
          zoom: mode == 'variable-zoom' ? 1.5 : 1,
        ),
      );
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _loadThreePages(tester, host);

      for (final step in [
        (1, true),
        (2, true),
        (3, true),
        (2, false),
        (1, false),
      ]) {
        await _lookAtPage(tester, step.$1, forward: step.$2);
        _expectPage(tester, step.$1);
        expect(host.requests, [
          2,
          3,
        ], reason: 'cached rows require no page fetch');
      }
      expect(
        host.page,
        3,
        reason: 'the host still owns its last received page',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('fullscreen scrolling updates the same page indicator', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全屏'));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _loadThreePages(tester, host);
    await _lookAtPage(tester, 2, forward: true);
    _expectPage(tester, 2);
    await _lookAtPage(tester, 1, forward: false);
    _expectPage(tester, 1);
    expect(host.requests, [2, 3]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pager buttons and input navigate from the visible page', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _loadThreePages(tester, host);
    await _lookAtPage(tester, 2, forward: true);
    _expectPage(tester, 2);
    await tester.tap(find.text('上一页'));
    await tester.pumpAndSettle();
    expect(host.requests, [2, 3, 1]);
    expect(host.rows.items, _rowsFor('A', 1));
    _expectPage(tester, 1);

    await _loadThreePagesAfterReset(tester, host);
    await _lookAtPage(tester, 1, forward: true);
    _expectPage(tester, 1);
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(host.requests.last, 2, reason: 'next follows visible page 1');
    expect(host.rows.items, _rowsFor('A', 2));

    await tester.enterText(find.byType(TextFormField), '4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(host.requests.last, 4);
    expect(host.rows.items, _rowsFor('A', 4));
    _expectPage(tester, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'leading rows do not invent pages and query changes reset tracking',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, leadingContent: true));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _loadThreePages(tester, host);
      await _lookAtPage(tester, 2, forward: true);
      _expectPage(tester, 2);
      _vertical(tester).position.jumpTo(0);
      await tester.pumpAndSettle();
      await _wheel(tester, 1);
      expect(find.text('前导分组'), findsOneWidget);
      expect(find.byKey(const ValueKey('anchor-local-draft')), findsOneWidget);
      _expectPage(tester, 1);
      expect(host.requests, [2, 3]);

      host.resetQuery();
      await tester.pumpAndSettle();
      _expectPage(tester, 1);
      expect(host.rows.items, ['local-draft', ..._rowsFor('B', 1)]);
      expect(_vertical(tester).position.pixels, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _loadThreePagesAfterReset(
  WidgetTester tester,
  _HarnessState host,
) async {
  await host.rows.loadNextPage();
  await tester.pumpAndSettle();
  await host.rows.loadNextPage();
  await tester.pumpAndSettle();
  expect(host.rows.items, [
    ..._rowsFor('A', 1),
    ..._rowsFor('A', 2),
    ..._rowsFor('A', 3),
  ]);
  _expectPage(tester, 1);
}
