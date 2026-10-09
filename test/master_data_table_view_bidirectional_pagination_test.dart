import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(
    this.scope,
    this.page,
    this.index, {
    this.version = 1,
    this.height,
  });

  final String scope;
  final int page;
  final int index;
  final int version;
  final double? height;

  String get id => '$scope-page-$page-row-$index';
}

List<_Row> _pageRows(String scope, int page) => [
  for (var index = 0; index < 20; index++) _Row(scope, page, index),
];

String _rowId(_Row row) => row.id;

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.primary = false,
    this.variableHeight = false,
    this.eagerPage = false,
    this.initialRowCount = 20,
    this.leadingContent = false,
    this.localSort = false,
    this.visiblePage,
    this.zoom = 1,
  });

  final bool primary;
  final bool variableHeight;
  final bool eagerPage;
  final int initialRowCount;
  final bool leadingContent;
  final bool localSort;
  final int? visiblePage;
  final double zoom;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final rows = MasterDataTableRowsController<_Row>();
  final primaryController = ScrollController();
  final requests = <int>[];
  final responses = <Completer<List<_Row>>>[];
  List<_Row> items = [];
  String scope = 'A';
  int page = 3;
  bool loading = false;
  String? error;
  Object revision = Object();

  @override
  void initState() {
    super.initState();
    items = _pageRows('A', 3).take(widget.initialRowCount).toList();
  }

  Future<void> load(int target) async {
    final requestedScope = scope;
    final response = Completer<List<_Row>>();
    requests.add(target);
    responses.add(response);
    setState(() {
      loading = true;
      error = null;
      if (widget.eagerPage) page = target;
    });
    try {
      final result = await response.future;
      if (!mounted || requestedScope != scope) return;
      setState(() {
        items = result;
        page = target;
        loading = false;
        revision = Object();
      });
    } catch (_) {
      if (!mounted || requestedScope != scope) return;
      setState(() {
        error = '上一页连接失败';
        loading = false;
      });
    }
  }

  void switchQuery() => setState(() {
    scope = 'B';
    page = 1;
    items = _pageRows('B', 1);
    loading = false;
    error = null;
    revision = Object();
  });

  double heightOf(_Row row) =>
      row.height ??
      (widget.variableHeight
          ? 24.0 + ((row.page * 3 + row.index) % 5) * 31.0
          : 28.0);

  @override
  void dispose() {
    primaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final table = MasterDataTableView<_Row>(
      columns: [
        MasterColumnDef<_Row>(
          key: 'id',
          label: '编号',
          width: 210,
          value: _rowId,
          sortable: widget.localSort,
        ),
        MasterColumnDef<_Row>(
          key: 'detail',
          label: '内容',
          width: 240,
          value: (row) => '明细 ${row.index} · v${row.version}',
          cellBuilder: (_, row) => SizedBox(
            key: ValueKey('anchor-${row.id}'),
            height: heightOf(row),
            child: Align(
              alignment: Alignment.topLeft,
              child: Text('明细 ${row.index} · v${row.version}'),
            ),
          ),
        ),
      ],
      items: items,
      unpagedItems: widget.leadingContent
          ? const [_Row('local', 0, 0)]
          : const [],
      leadingGroups: widget.leadingContent
          ? const [
              MasterDataGroup<_Row>(
                id: 'notice',
                title: '前置分组',
                items: [_Row('group', 0, 0)],
              ),
            ]
          : null,
      rowsController: rows,
      rowKeyOf: _rowId,
      rowVisible: widget.visiblePage == null
          ? null
          : (row) => row.page == widget.visiblePage,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      currentPage: page,
      totalPages: 5,
      paginationScope: scope,
      paginationRevision: revision,
      onPageChange: load,
      loadingMore: loading,
      error: error,
      onRetry: () => load(page),
      primary: widget.primary,
    );
    return MaterialApp(
      home: Scaffold(
        body: Transform.scale(
          scale: widget.zoom,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 700,
            height: 430,
            child: widget.primary
                ? PrimaryScrollController(
                    controller: primaryController,
                    child: table,
                  )
                : table,
          ),
        ),
      ),
    );
  }
}

ScrollableState _vertical(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .firstWhere((state) => state.position.axis == Axis.vertical);

Future<void> _wheel(WidgetTester tester, double dy, {double dx = 0}) async {
  final list = find.byType(ListView).first;
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(list)));
  await tester.sendEventToBinding(pointer.scroll(Offset(dx, dy)));
  await tester.pump();
  await tester.pump();
}

Future<void> _top(WidgetTester tester) async {
  final position = _vertical(tester).position;
  position.jumpTo(position.minScrollExtent);
  await tester.pump();
}

Future<void> _bottom(WidgetTester tester) async {
  final position = _vertical(tester).position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pump();
}

Finder _anchor(int page, [int index = 0]) =>
    find.byKey(ValueKey('anchor-A-page-$page-row-$index'));

List<String> _idsForPages(Iterable<int> pages, {String scope = 'A'}) => [
  for (final page in pages) ..._pageRows(scope, page).map(_rowId),
];

void main() {
  for (final mode in ['table', 'primary']) {
    for (final variableHeight in [false, true]) {
      testWidgets(
        '$mode prepends pages 2 and 1 while preserving the visible row '
        '(${variableHeight ? 'variable' : 'fixed'} heights)',
        (tester) async {
          final key = GlobalKey<_HarnessState>();
          await tester.pumpWidget(
            _Harness(
              key: key,
              primary: mode == 'primary',
              variableHeight: variableHeight,
            ),
          );
          await tester.pumpAndSettle();
          final host = key.currentState!;
          await _top(tester);
          expect(
            host.requests,
            isEmpty,
            reason: 'layout does not fetch a page',
          );
          expect(_anchor(3), findsOneWidget);
          final thirdPageTop = tester.getTopLeft(_anchor(3)).dy;

          await _wheel(tester, -150);
          await _wheel(tester, -150);
          expect(host.requests, [2], reason: 'in-flight loads do not repeat');
          expect(host.rows.items.map(_rowId), _idsForPages([3]));
          expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
          host.responses.single.complete(_pageRows('A', 2));
          await tester.pumpAndSettle();

          expect(host.rows.items.map(_rowId), _idsForPages([2, 3]));
          // Page 2 was fetched above the anchor; page 3 is still under the eyes.
          expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
          expect(_anchor(3), findsOneWidget);
          expect(
            tester.getTopLeft(_anchor(3)).dy,
            closeTo(thirdPageTop, 1),
            reason:
                'prepending keeps the previously visible row under the eyes',
          );
          expect(_vertical(tester).position.pixels, greaterThan(0));

          await _top(tester);
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextFormField, '2'), findsOneWidget);
          expect(host.requests, [
            2,
          ], reason: 'programmatic motion does not load');
          expect(_anchor(2), findsOneWidget);
          final secondPageTop = tester.getTopLeft(_anchor(2)).dy;
          await _wheel(tester, -150);
          expect(host.requests, [2, 1]);
          host.responses.last.complete(_pageRows('A', 1));
          await tester.pumpAndSettle();

          expect(host.rows.items.map(_rowId), _idsForPages([1, 2, 3]));
          expect(find.widgetWithText(TextFormField, '2'), findsOneWidget);
          expect(_anchor(2), findsOneWidget);
          expect(tester.getTopLeft(_anchor(2)).dy, closeTo(secondPageTop, 1));
          await _top(tester);
          await tester.pumpAndSettle();
          expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
          await _wheel(tester, -150);
          await _wheel(tester, -150);
          expect(host.requests, [2, 1], reason: 'page one has no predecessor');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'after prepending page two, downward scrolling requests page four',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _wheel(tester, -150);
      host.responses.single.complete(_pageRows('A', 2));
      await tester.pumpAndSettle();
      expect(host.requests, [2]);

      await _bottom(tester);
      await _wheel(tester, 150);
      expect(host.requests, [
        2,
        4,
      ], reason: 'page three is already in the window');
      host.responses.last.complete(_pageRows('A', 4));
      await tester.pumpAndSettle();
      expect(host.rows.items.map(_rowId), _idsForPages([2, 3, 4]));
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      await _bottom(tester);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, '4'), findsOneWidget);
      expect(host.requests, [
        2,
        4,
      ], reason: 'visible page changes do not fetch');
      expect(host.rows.items.map(_rowId).toSet(), hasLength(60));
    },
  );

  testWidgets(
    'failed eager previous page preserves rows and retries that page',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, eagerPage: true));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _wheel(tester, -150);
      expect(
        host.page,
        2,
        reason: 'the host advances before the response arrives',
      );
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      host.responses.single.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(host.rows.items.map(_rowId), _idsForPages([3]));
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      await _wheel(tester, -150);
      expect(host.requests, [2], reason: 'failure requires an explicit retry');

      // Both a leading inline error and the shared table footer are supported.
      if (find.text('重试').evaluate().isEmpty) await _bottom(tester);
      await tester.ensureVisible(find.text('重试'));
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(host.requests, [2, 2]);
      host.responses.last.complete(_pageRows('A', 2));
      await tester.pumpAndSettle();
      expect(host.rows.items.map(_rowId), _idsForPages([2, 3]));
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('controller uses the loaded boundaries in both directions', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final host = key.currentState!;

    final previous = host.rows.loadPreviousPage();
    await tester.pump();
    expect(host.requests, [2]);
    host.responses.single.complete(_pageRows('A', 2));
    await previous;
    await tester.pumpAndSettle();

    final next = host.rows.loadNextPage();
    await tester.pump();
    expect(host.requests, [2, 4]);
    host.responses.last.complete(_pageRows('A', 4));
    await next;
    await tester.pumpAndSettle();
    expect(host.rows.items.map(_rowId), _idsForPages([2, 3, 4]));
  });

  testWidgets('scope change invalidates a pending previous-page response', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _wheel(tester, -150);
    expect(host.requests, [2]);
    host.switchQuery();
    await tester.pumpAndSettle();
    expect(host.rows.items.map(_rowId), _idsForPages([1], scope: 'B'));
    expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
    expect(_vertical(tester).position.pixels, 0);

    await _bottom(tester);
    await _wheel(tester, 150);
    expect(host.requests, [2, 2]);
    host.responses.first.complete(_pageRows('A', 2));
    await tester.pump();
    await tester.pump();
    expect(host.rows.items.map(_rowId), _idsForPages([1], scope: 'B'));
    host.responses.last.complete(_pageRows('B', 2));
    await tester.pumpAndSettle();
    expect(host.rows.items.map(_rowId), _idsForPages([1, 2], scope: 'B'));
    expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short pages retain their anchor and leading content stays put', (
    tester,
  ) async {
    final shortKey = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: shortKey, initialRowCount: 1));
    await tester.pumpAndSettle();
    final shortHost = shortKey.currentState!;
    final oldRowTop = tester.getTopLeft(_anchor(3)).dy;
    await _wheel(tester, -150);
    expect(shortHost.requests, [2]);
    shortHost.responses.single.complete([const _Row('A', 2, 0)]);
    await tester.pumpAndSettle();
    expect(shortHost.rows.items.map(_rowId), [
      'A-page-2-row-0',
      'A-page-3-row-0',
    ]);
    expect(_anchor(3), findsOneWidget);
    expect(tester.getTopLeft(_anchor(3)).dy, closeTo(oldRowTop, 1));

    final prefixKey = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: prefixKey, leadingContent: true));
    await tester.pumpAndSettle();
    final prefixHost = prefixKey.currentState!;
    final group = find.text('前置分组');
    final draft = find.byKey(const ValueKey('anchor-local-page-0-row-0'));
    expect(group, findsOneWidget);
    expect(draft, findsOneWidget);
    final groupTop = tester.getTopLeft(group).dy;
    final draftTop = tester.getTopLeft(draft).dy;
    await _wheel(tester, -150);
    prefixHost.responses.single.complete(_pageRows('A', 2));
    await tester.pumpAndSettle();
    expect(prefixHost.rows.items.map(_rowId), [
      'local-page-0-row-0',
      ..._idsForPages([2, 3]),
    ]);
    expect(group, findsOneWidget);
    expect(draft, findsOneWidget);
    expect(tester.getTopLeft(group).dy, closeTo(groupTop, 1));
    expect(tester.getTopLeft(draft).dy, closeTo(draftTop, 1));
    expect(_vertical(tester).position.pixels, closeTo(0, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('response preserves the row reached while prepend was pending', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, primary: true));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _wheel(tester, -150);
    expect(host.requests, [2]);

    await _wheel(tester, 180);
    expect(_vertical(tester).position.pixels, greaterThan(0));
    final currentAnchor = _anchor(3, 5);
    expect(currentAnchor, findsOneWidget);
    expect(
      tester
          .getRect(currentAnchor)
          .overlaps(tester.getRect(find.byType(ListView).first)),
      isTrue,
      reason: 'the reader moved to another visible row during the request',
    );
    final anchorTopAtResponse = tester.getTopLeft(currentAnchor).dy;
    host.responses.single.complete(_pageRows('A', 2));
    await tester.pumpAndSettle();
    expect(host.requests, [2]);
    expect(host.rows.items.map(_rowId), _idsForPages([2, 3]));
    expect(currentAnchor, findsOneWidget);
    expect(
      tester.getTopLeft(currentAnchor).dy,
      closeTo(anchorTopAtResponse, 1),
      reason:
          'preserve the response-time position, not the request-time position',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen prepend preserves the visible variable-height row', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, variableHeight: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全屏'));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    expect(_anchor(3), findsOneWidget);
    final oldRowTop = tester.getTopLeft(_anchor(3)).dy;
    await _wheel(tester, -150);
    expect(host.requests, [2]);
    host.responses.single.complete(_pageRows('A', 2));
    await tester.pumpAndSettle();
    expect(host.rows.items.map(_rowId), _idsForPages([2, 3]));
    expect(_anchor(3), findsOneWidget);
    expect(tester.getTopLeft(_anchor(3)).dy, closeTo(oldRowTop, 1));
    expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
    await _top(tester);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '2'), findsOneWidget);
    expect(host.requests, [2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'horizontal and Shift wheel gestures do not load previous pages',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _wheel(tester, 0, dx: -150);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester, -150);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(host.requests, isEmpty);
      expect(host.rows.items.map(_rowId), _idsForPages([3]));

      await _wheel(tester, -150);
      expect(host.requests, [
        2,
      ], reason: 'ordinary upward scrolling still works');
      host.responses.single.complete(_pageRows('A', 2));
      await tester.pumpAndSettle();
      expect(host.rows.items.map(_rowId), _idsForPages([2, 3]));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'overlapping previous page keeps the newest row version only once',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _wheel(tester, -150);
      host.responses.single.complete([
        ..._pageRows('A', 2),
        const _Row('A', 3, 0, version: 2, height: 144),
      ]);
      await tester.pumpAndSettle();

      final overlapping = host.rows.items.where(
        (row) => row.id == 'A-page-3-row-0',
      );
      expect(host.rows.items, hasLength(40));
      expect(overlapping, hasLength(1));
      expect(overlapping.single.version, 2);
      expect(overlapping.single.height, 144);
      expect(_anchor(3), findsOneWidget);
      expect(tester.getSize(_anchor(3)).height, 144);
      expect(find.text('明细 0 · v2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local sorting can put the previous page after the visible anchor',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, localSort: true));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await tester.tap(find.text('编号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从大到小'));
      await tester.pumpAndSettle();

      // Descending text order puts page 3 before page 2, with row 9 first.
      final oldFirst = _anchor(3, 9);
      expect(oldFirst, findsOneWidget);
      final oldTop = tester.getTopLeft(oldFirst).dy;
      final oldOffset = _vertical(tester).position.pixels;
      await _wheel(tester, -150);
      expect(host.requests, [2]);
      host.responses.single.complete(_pageRows('A', 2));
      await tester.pumpAndSettle();

      expect(host.rows.items, hasLength(40));
      expect(oldFirst, findsOneWidget);
      expect(tester.getTopLeft(oldFirst).dy, closeTo(oldTop, 1));
      expect(
        _vertical(tester).position.pixels,
        closeTo(oldOffset, 1),
        reason:
            'rows sorted after the visible anchor add no leading scroll extent',
      );
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('previous page can recover a completely filtered empty table', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, visiblePage: 2));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    expect(host.rows.items, isEmpty);
    expect(find.text('暂无数据'), findsOneWidget);
    expect(host.rows.isAppending, isFalse);

    final previous = host.rows.loadPreviousPage();
    await tester.pump();
    expect(host.requests, [2]);
    host.responses.single.complete(_pageRows('A', 2));
    await previous;
    await tester.pumpAndSettle();

    expect(host.rows.items.map(_rowId), _idsForPages([2]));
    expect(host.rows.isAppending, isFalse);
    expect(find.text('暂无数据'), findsNothing);
    expect(find.widgetWithText(TextFormField, '2'), findsOneWidget);
    expect(_anchor(2), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'zoomed variable-height prepend preserves the screen-space anchor',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        _Harness(key: key, variableHeight: true, zoom: 1.5),
      );
      await tester.pumpAndSettle();
      final host = key.currentState!;
      final oldScreenTop = tester.getTopLeft(_anchor(3)).dy;
      await _wheel(tester, -150);
      expect(host.requests, [2]);
      host.responses.single.complete(_pageRows('A', 2));
      await tester.pumpAndSettle();

      expect(host.rows.items.map(_rowId), _idsForPages([2, 3]));
      expect(_anchor(3), findsOneWidget);
      expect(tester.getTopLeft(_anchor(3)).dy, closeTo(oldScreenTop, 1));
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
