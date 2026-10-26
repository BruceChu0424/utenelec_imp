import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';

class _Row {
  const _Row(this.id, this.version, this.height);
  final int id;
  final int version;
  final double height;
}

PagedResult<_Row> _page(int page, {int version = 0, bool shifted = false}) {
  final start = (page - 1) * 14 + (shifted ? 1 : 0);
  return PagedResult(
    items: [
      for (var id = start; id < start + 14; id++)
        _Row(id, version, 34 + (id % 3) * 12 + (version > 0 ? 5 : 0)),
    ],
    page: page,
    size: 14,
    total: 42,
    totalPages: 3,
  );
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final reader = ScopedPagedRead<_Row>();
  final rows = MasterDataTableRowsController<_Row>();
  PagedResult<_Row>? result;
  bool loading = false;
  String? error;
  int request = 0;
  Future<PagedResult<_Row>> Function(int) source = (page) async => _page(page);

  @override
  void initState() {
    super.initState();
    unawaited(load(1));
  }

  Future<void> load(int page, {bool cached = true}) async {
    final generation = ++request;
    final future = reader.read(
      page,
      scope: 'fixed-query',
      fetchPage: source,
      isCurrent: () => mounted,
      useCache: cached,
      canPrefetch: () => false,
    );
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final next = await future;
      if (!mounted || generation != request) return;
      setState(() => result = next);
    } catch (failure) {
      if (!mounted || generation != request) return;
      setState(() {
        error = failure is ApiException ? failure.message : '$failure';
        if (pagedReadAccessDenied(failure)) result = null;
      });
    } finally {
      if (mounted && generation == request) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> refresh() =>
      load(rows.visiblePage ?? result!.page, cached: false);

  @override
  void dispose() {
    reader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 700,
        height: 390,
        child: MasterDataTableView<_Row>(
          columns: [
            MasterColumnDef<_Row>(
              key: 'label',
              label: '名称',
              width: 400,
              value: (row) => '${row.id} v${row.version}',
              cellBuilder: (_, row) => SizedBox(
                key: ValueKey('anchor-${row.id}'),
                height: row.height,
                child: Text('${row.id} v${row.version}'),
              ),
            ),
          ],
          expensiveRowMounts: false,
          rowKeyOf: (row) => '${row.id}',
          rowsController: rows,
          items: result?.items ?? const [],
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          currentPage: result?.page ?? 1,
          totalPages: result?.totalPages ?? 3,
          paginationScope: 'fixed-query',
          paginationRevision: result,
          isLoading: loading && result == null,
          loadingMore: loading && result != null,
          error: error,
          onPageChange: load,
        ),
      ),
    ),
  );
}

Future<_HarnessState> _three(WidgetTester tester) async {
  final key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(_Harness(key: key));
  await tester.pumpAndSettle();
  final host = key.currentState!;
  await host.rows.loadNextPage();
  await tester.pumpAndSettle();
  await host.rows.loadNextPage();
  await tester.pumpAndSettle();
  expect(host.rows.items, hasLength(42));
  expect(host.rows.visiblePage, 1);
  return host;
}

ScrollableState _scroll(WidgetTester tester) => Scrollable.of(
  tester.element(
    find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('anchor-'),
        )
        .first,
  ),
  axis: Axis.vertical,
);

Future<void> _look(WidgetTester tester, int id) async {
  final viewport = _scroll(tester);
  final target = find.byKey(ValueKey('anchor-$id'));
  for (var step = 0; target.evaluate().isEmpty && step < 30; step++) {
    viewport.position.jumpTo(
      (viewport.position.pixels + 160).clamp(
        0,
        viewport.position.maxScrollExtent,
      ),
    );
    await _frames(tester);
  }
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(target));
  await _frames(tester);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

({Finder row, double top}) _firstVisible(WidgetTester tester) {
  ({Finder row, double top})? first;
  for (var id = 0; id < 42; id++) {
    final row = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey &&
          (widget.key! as ValueKey).value ==
              ('pagination-row', ('data', '$id')),
    );
    if (row.evaluate().length != 1) continue;
    final box = tester.renderObject<RenderBox>(row);
    final object = RenderAbstractViewport.maybeOf(box);
    if (object is! RenderBox) continue;
    final viewport = object as RenderBox;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    if (top + box.size.height <= .5 || top >= viewport.size.height) continue;
    if (first == null || top < first.top) first = (row: row, top: top);
  }
  return first!;
}

double _localTop(WidgetTester tester, Finder row) {
  final box = tester.renderObject<RenderBox>(row);
  return box
      .localToGlobal(Offset.zero, ancestor: RenderAbstractViewport.maybeOf(box))
      .dy;
}

void main() {
  test('business projections preserve each page and an empty view binding', () {
    final session = PagedReadWindowSession<int>(isCurrent: () => true);
    const original = PagedResult<int>(
      items: [1, 2],
      page: 1,
      size: 2,
      total: 4,
      totalPages: 2,
    );
    session.bindResult(
      original,
      replacementPages: {
        1: [1, 2],
        2: [3, 4],
      },
    );
    List<String> project(List<int> rows) => rows
        .where((value) => value.isEven)
        .map((value) => 'view-$value')
        .toList();
    final view = project(original.items);
    projectReadWindowBinding(
      original.items,
      view,
      project: project,
      projectionKey: ['even', 1],
    );
    final binding = readWindowBindingOf(view)!;
    expect(binding.replacementPages, {
      1: ['view-2'],
      2: ['view-4'],
    });
    binding.attachPresentation(
      Object(),
      retainedPages: () => [1, 2],
      visiblePage: () => 1,
      isCurrent: () => true,
    );
    expect(session.capture()!.pages, [1, 2]);
    final emptyView = <String>[];
    projectReadWindowBinding(
      original.items,
      emptyView,
      project: (_) => <String>[],
      projectionKey: ['even', 2],
    );
    expect(readWindowBindingOf(emptyView)!.replacementPages, {
      1: <String>[],
      2: <String>[],
    });
    expect(readWindowBindingOf(emptyView)!.sameSession(binding), isFalse);
    session.invalidate();
    expect(binding.isCurrent, isFalse);
  });

  for (final (initialPage, finalPage) in [(1, 1), (1, 2), (2, 2)]) {
    testWidgets(
      'fresh window keeps page $initialPage to $finalPage with changed heights',
      (tester) async {
        final host = await _three(tester);
        if (initialPage == 2) await _look(tester, 17);
        final first = Completer<PagedResult<_Row>>();
        final calls = <int>[];
        final shifted = finalPage != 1;
        host.source = (page) {
          calls.add(page);
          return page == 1
              ? first.future
              : Future.value(_page(page, version: 1, shifted: shifted));
        };
        final before = host.rows.items.toList();
        final pending = host.refresh();
        await tester.pump();
        expect(host.rows.items, orderedEquals(before));
        if (initialPage == 1 && finalPage == 2) await _look(tester, 17);
        expect(host.rows.visiblePage, finalPage);
        final anchor = _firstVisible(tester);
        final state = tester.state(find.byType(MasterDataTableView<_Row>));
        first.complete(_page(1, version: 1, shifted: shifted));
        await pending;
        await tester.pumpAndSettle();
        expect(calls, initialPage == 1 ? [1, 2, 3] : [2, 1, 3]);
        expect(host.result!.page, finalPage);
        expect(host.rows.visiblePage, finalPage);
        expect(
          host.rows.items.map((row) => row.id),
          List.generate(42, (i) => i + (shifted ? 1 : 0)),
        );
        expect(host.rows.items.every((row) => row.version == 1), isTrue);
        expect(_localTop(tester, anchor.row), closeTo(anchor.top, .6));
        expect(
          tester.state(find.byType(MasterDataTableView<_Row>)),
          same(state),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed fresh window keeps old rows; denied read clears them', (
    tester,
  ) async {
    final host = await _three(tester);
    await _look(tester, 17);
    final old = host.rows.items.toList();
    final pixels = _scroll(tester).position.pixels;
    host.source = (_) => Future.error(ApiException('NETWORK', 'offline'));
    await host.refresh();
    await tester.pumpAndSettle();
    expect(host.rows.items, orderedEquals(old));
    expect(_scroll(tester).position.pixels, pixels);
    host.source = (_) =>
        Future.error(ApiException('FORBIDDEN', 'denied', httpStatus: 403));
    await host.refresh();
    await tester.pumpAndSettle();
    expect(host.rows.items, isEmpty);
    expect(find.text('denied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty refresh retires all pages and explicit goto starts one window',
    (tester) async {
      final host = await _three(tester);
      host.rows.goToPage(1);
      await tester.pumpAndSettle();
      expect(host.rows.items, hasLength(14));
      expect(host.rows.visiblePage, 1);
      host.source = (_) async => const PagedResult<_Row>(
        items: [],
        page: 1,
        size: 14,
        total: 0,
        totalPages: 0,
      );
      await host.refresh();
      await tester.pumpAndSettle();
      expect(host.rows.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
