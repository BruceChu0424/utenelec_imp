import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _Row {
  const _Row(this.id, this.label);
  final String id;
  final String label;
}

PagedResult<_Row> _page(int page, {String suffix = ''}) => PagedResult(
  items: [
    for (var i = 0; i < 16; i++) _Row('$page-$i', 'page-$page-row-$i$suffix'),
  ],
  page: page,
  size: 16,
  total: 48,
  totalPages: 3,
);

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.openDetails = false});

  final bool openDetails;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final list = PagedListController<_Row>()..page = _page(1);
  final rows = MasterDataTableRowsController<_Row>();
  final opened = <String>[];

  Future<void> refresh(Future<PagedResult<_Row>> result) {
    // This fixture can receive an already failed second-page future. Observe it
    // now while the ordered window revalidation still awaits the first page.
    result.ignore();
    final target = list.currentPage;
    return refreshWindow(
      (page) =>
          page == target ? result : Future.value(_page(page, suffix: '-fresh')),
    );
  }

  Future<void> refreshWindow(Future<PagedResult<_Row>> Function(int) fetch) =>
      list.load(
        list.currentPage,
        silent: true,
        fetch: () => fetch(list.currentPage),
        fetchPage: fetch,
      );

  @override
  void dispose() {
    list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 700,
        height: 400,
        child: ListenableBuilder(
          listenable: list,
          builder: (context, _) => MasterDataTableView<_Row>(
            columns: [
              MasterColumnDef<_Row>(
                key: 'label',
                label: '名称',
                width: 300,
                value: (row) => row.label,
                cellBuilder: (_, row) =>
                    _RowProbe(key: ValueKey('probe-${row.id}'), row: row),
              ),
            ],
            rowKeyOf: (row) => row.id,
            rowsController: rows,
            items: list.page?.items ?? const [],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: widget.openDetails
                ? (row) {
                    opened.add(row.id);
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => Scaffold(body: Text('详情 ${row.id}')),
                      ),
                    );
                  }
                : null,
            isLoading: list.isLoadingFirst,
            loadingMore: list.isLoadingMore,
            isRefreshing: list.refreshing,
            refreshError: list.refreshError,
            refreshedPages: list.refreshedPages,
            onRetainedPagesChanged: list.retainPages,
            onRetry: () {},
            currentPage: list.currentPage,
            totalPages: list.totalPages,
            paginationScope: 'same query',
            paginationRevision: list.paginationRevision,
            onPageChange: (page) =>
                list.load(page, fetch: () async => _page(page)),
          ),
        ),
      ),
    ),
  );
}

class _RowProbe extends StatefulWidget {
  const _RowProbe({super.key, required this.row});
  final _Row row;

  @override
  State<_RowProbe> createState() => _RowProbeState();
}

class _RowProbeState extends State<_RowProbe> {
  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey('anchor-${widget.row.id}'),
    height: 40,
    child: Text(widget.row.label),
  );
}

class _MapProbe extends StatefulWidget {
  const _MapProbe(this.row);
  final Map<String, dynamic> row;

  @override
  State<_MapProbe> createState() => _MapProbeState();
}

class _MapProbeState extends State<_MapProbe> {
  @override
  Widget build(BuildContext context) => Text(widget.row['proof'] as String);
}

Map<String, dynamic> _mapRow(int version) => {
  'proof': 'same visible text',
  '__hidden': {
    'version': version,
    'sources': [1, 2],
  },
};

class _MapHarness extends StatefulWidget {
  const _MapHarness({super.key});

  @override
  State<_MapHarness> createState() => _MapHarnessState();
}

class _MapHarnessState extends State<_MapHarness> {
  final rows = MasterDataTableRowsController<Map<String, dynamic>>();
  List<Map<String, dynamic>> incoming = [_mapRow(1)];
  Map<int, List<Map<String, dynamic>>> refreshed = const {};
  bool busy = false;

  void begin() => setState(() => busy = true);
  void accept(int version) => setState(() {
    incoming = [_mapRow(version)];
    refreshed = {1: incoming};
    busy = false;
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: MasterDataTableView<Map<String, dynamic>>(
        columns: [
          MasterColumnDef<Map<String, dynamic>>(
            key: 'proof',
            label: '记录',
            width: 240,
            value: (row) => row['proof'] as String,
            cellBuilder: (_, row) => _MapProbe(row),
          ),
        ],
        items: incoming,
        rowsController: rows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        isRefreshing: busy,
        refreshedPages: refreshed,
        paginationScope: 'same query',
        paginationRevision: 1,
        onPageChange: (_) async {},
      ),
    ),
  );
}

void main() {
  testWidgets(
    'identical report JSON retains unkeyed row State but hidden changes publish',
    (tester) async {
      final key = GlobalKey<_MapHarnessState>();
      await tester.pumpWidget(_MapHarness(key: key));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      final originalRow = host.rows.items.single;
      final originalState = tester.state(find.byType(_MapProbe));
      host.begin();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      host.accept(1);
      await tester.pumpAndSettle();
      expect(host.rows.items.single, same(originalRow));
      expect(tester.state(find.byType(_MapProbe)), same(originalState));
      host.begin();
      await tester.pump();
      host.accept(2);
      await tester.pumpAndSettle();
      expect(host.rows.items.single, isNot(same(originalRow)));
      expect((host.rows.items.single['__hidden'] as Map)['version'], 2);
      expect(find.text('same visible text'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh row lowers the body and leaves double-click navigation live',
    (tester) async {
      final hostKey = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: hostKey, openDetails: true));
      await tester.pumpAndSettle();
      final host = hostKey.currentState!;
      final anchor = find.byKey(const ValueKey('anchor-1-0'));
      final headerY = tester.getTopLeft(find.text('名称')).dy;
      final rowY = tester.getTopLeft(anchor).dy;
      final rowState = tester.state(find.byKey(const ValueKey('probe-1-0')));
      final table = find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView,
      );
      final tableState = tester.state(table);
      final position = Scrollable.of(
        tester.element(anchor),
        axis: Axis.vertical,
      ).position;
      final pending = Completer<PagedResult<_Row>>();
      final request = host.refresh(pending.future);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final midY = tester.getTopLeft(anchor).dy;
      expect(midY, greaterThan(rowY));
      expect(tester.getTopLeft(find.text('名称')).dy, headerY);
      await tester.pump(const Duration(milliseconds: 300));
      final statusHeight = tester
          .getSize(find.byKey(const ValueKey('master-table-refresh-row')))
          .height;
      expect(statusHeight, greaterThanOrEqualTo(36));
      expect(tester.getTopLeft(anchor).dy, closeTo(rowY + statusHeight, 0.1));
      expect(
        Scrollable.of(tester.element(anchor), axis: Axis.vertical).position,
        same(position),
      );
      expect(tester.state(table), same(tableState));
      expect(
        tester.state(find.byKey(const ValueKey('probe-1-0'))),
        same(rowState),
      );

      await tester.tap(anchor);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(anchor);
      await tester.pumpAndSettle();
      expect(host.opened, ['1-0']);
      expect(find.text('详情 1-0'), findsOneWidget);
      pending.complete(_page(1, suffix: '-late'));
      await request;
      await tester.pumpAndSettle();
      expect(find.text('详情 1-0'), findsOneWidget);
      expect(host.opened, ['1-0']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unchanged data only collapses the status row without remounting data',
    (tester) async {
      final hostKey = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: hostKey));
      await tester.pumpAndSettle();
      final host = hostKey.currentState!;
      final accepted = host.list.page!;
      final row = find.byKey(const ValueKey('anchor-1-0'));
      final rowState = tester.state(find.byKey(const ValueKey('probe-1-0')));
      final table = find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView,
      );
      final tableState = tester.state(table);
      final originalY = tester.getTopLeft(row).dy;
      final pending = Completer<PagedResult<_Row>>();
      final request = host.refresh(pending.future);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.getTopLeft(row).dy, greaterThan(originalY));
      pending.complete(accepted);
      await request;
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(row).dy, closeTo(originalY, 0.1));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('master-table-refresh-row')))
            .height,
        0,
      );
      expect(tester.state(table), same(tableState));
      expect(
        tester.state(find.byKey(const ValueKey('probe-1-0'))),
        same(rowState),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('background reads retain rows, table State and scroll window', (
    tester,
  ) async {
    final hostKey = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: hostKey));
    await tester.pumpAndSettle();
    final host = hostKey.currentState!;
    await host.rows.loadNextPage();
    await tester.pumpAndSettle();
    expect(host.rows.items, hasLength(32));

    final table = find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView,
    );
    final state = tester.state(table);
    final scroll = Scrollable.of(
      tester.element(find.byKey(const ValueKey('anchor-1-0'))),
      axis: Axis.vertical,
    ).position;
    // Stay away from the look-ahead boundary while testing revalidation alone.
    scroll.jumpTo(120);
    await tester.pumpAndSettle();
    final pixels = scroll.pixels;
    final pending = Completer<PagedResult<_Row>>();
    final request = host.refresh(pending.future);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('master-table-refresh-progress')),
      findsOneWidget,
    );
    expect(host.rows.items, hasLength(32));
    expect(tester.state(table), same(state));
    expect(scroll.pixels, pixels);

    pending.complete(_page(2, suffix: '-fresh'));
    await request;
    await tester.pumpAndSettle();
    expect(host.rows.items, hasLength(32));
    expect(host.rows.items.last.label, endsWith('-fresh'));
    expect(tester.state(table), same(state));
    expect(scroll.pixels, pixels);
    expect(
      find.byKey(const ValueKey('master-table-refresh-progress')),
      findsNothing,
    );

    await host.refresh(
      Future<PagedResult<_Row>>.error(ApiException('NETWORK', 'offline')),
    );
    await tester.pumpAndSettle();
    expect(find.text('更新失败，显示上次数据'), findsOneWidget);
    expect(host.rows.items, hasLength(32));
    expect(tester.state(table), same(state));
    expect(scroll.pixels, pixels);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a shifted window removes deleted rows atomically', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await host.rows.loadNextPage();
    await tester.pumpAndSettle();
    final oldRows = host.rows.items.map((row) => row.id).toList();
    final source = [for (var page = 1; page <= 3; page++) ..._page(page).items]
      ..removeAt(0);
    PagedResult<_Row> shifted(int page) => PagedResult(
      items: source.skip((page - 1) * 16).take(16).toList(),
      page: page,
      size: 16,
      total: source.length,
      totalPages: 3,
    );
    final lastPage = Completer<PagedResult<_Row>>();
    final request = host.refreshWindow(
      (page) => page == 2 ? lastPage.future : Future.value(shifted(page)),
    );
    await tester.pump();
    await tester.pump();
    expect(host.rows.items.map((row) => row.id), oldRows);
    await host.rows.loadNextPage();
    expect(
      host.list.currentPage,
      2,
      reason: 'background refresh blocks appending',
    );
    lastPage.complete(shifted(2));
    await request;
    await tester.pumpAndSettle();
    expect(
      host.rows.items.map((row) => row.id),
      source.take(32).map((row) => row.id),
    );
    expect(host.rows.items.any((row) => row.id == '1-0'), isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('refresh feedback remains usable at 200% in $brightness', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var retries = 0;
      final refreshing = ValueNotifier(true);
      addTearDown(refreshing.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: refreshing,
                builder: (_, busy, _) => MasterDataTableView<String>(
                  columns: [
                    MasterColumnDef<String>(
                      key: 'value',
                      label: '名称',
                      width: 200,
                      value: (row) => row,
                    ),
                  ],
                  items: const ['已有数据'],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  isRefreshing: busy,
                  refreshError: busy ? null : '连接暂时不可用',
                  onRetry: () => retries++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final progress = tester.widget<CircularProgressIndicator>(
        find.byKey(const ValueKey('master-table-refresh-progress')),
      );
      expect(
        progress.value,
        0.5,
        reason: 'reduced motion uses a static indicator',
      );
      refreshing.value = false;
      await tester.pumpAndSettle();
      expect(find.text('已有数据'), findsOneWidget);
      await tester.tap(find.text('重试'));
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
