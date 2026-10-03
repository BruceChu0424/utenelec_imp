import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id, this.height);
  final String id;
  final double height;
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    this.smallPages = false,
    this.groupsOnly = false,
    this.bigPages = false,
  });
  final bool smallPages;
  final bool groupsOnly;
  final bool bigPages;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final rows = MasterDataTableRowsController<_Row>();
  final selected = <String>{};
  final requested = <int>[];
  int page = 1;
  String scope = 'a';
  bool loading = false;
  List<_Row> get items => [
    for (
      var index = 0;
      index <
          (widget.smallPages
              ? 1
              : widget.bigPages
              ? 500
              : 20);
      index++
    )
      _Row(
        '$scope-$page-$index',
        widget.smallPages ? 24 : 30.0 + (index % 3) * 13,
      ),
  ];
  Future<void> load(int next) async {
    requested.add(next);
    setState(() => loading = true);
    await Future<void>.value();
    if (mounted) {
      setState(() {
        page = next;
        loading = false;
      });
    }
  }

  void query() => setState(() {
    scope = 'b';
    page = 1;
    selected.clear();
  });
  void selectFirst() => setState(() => selected.add('a-1-0'));
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: MasterDataTableView<_Row>(
        columns: [
          MasterColumnDef<_Row>(
            key: 'id',
            label: '业务行',
            width: 260,
            value: (row) => row.id,
            cellBuilder: (_, row) => SizedBox(
              key: ValueKey('row-${row.id}'),
              height: row.height,
              child: Text(row.id),
            ),
          ),
        ],
        items: items,
        rowsController: rows,
        rowKeyOf: (row) => row.id,
        idOf: (row) => row.id,
        rowVisible: widget.groupsOnly ? (_) => false : null,
        leadingGroups: widget.groupsOnly
            ? const [
                MasterDataGroup<_Row>(
                  id: 'summary',
                  title: '参考汇总',
                  items: [_Row('summary-fixed', 34)],
                  total: 1,
                ),
              ]
            : null,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        currentPage: page,
        totalPages: widget.smallPages ? 12 : 15,
        paginationScope: scope,
        loadingMore: loading,
        onPageChange: load,
        maxRetainedPages: widget.bigPages ? 5 : 2,
        maxRetainedRows: widget.bigPages ? 1000 : 40,
        virtualized: widget.bigPages,
        selectable: true,
        selectedIds: selected,
        onSelectedIdsChanged: (value) => setState(() {
          selected
            ..clear()
            ..addAll(value);
        }),
      ),
    ),
  );
}

ScrollableState _body(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(MasterDataTableView<_Row>),
        matching: find.byType(Scrollable),
      ),
    )
    .firstWhere(
      (state) =>
          state.position.axis == Axis.vertical &&
          state.position.hasContentDimensions,
    );

void main() {
  testWidgets(
    '500-row pages obey the 1000-row window instead of retaining all default five pages',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, bigPages: true));
      await tester.pumpAndSettle();
      for (var iteration = 0; iteration < 6; iteration++) {
        _body(tester).position.jumpTo(_body(tester).position.maxScrollExtent);
        await tester.pumpAndSettle();
        await key.currentState!.rows.loadNextPage();
        await tester.pumpAndSettle();
        expect(key.currentState!.rows.items.length, lessThanOrEqualTo(1000));
      }
      expect(key.currentState!.page, greaterThan(5));
      expect(
        key.currentState!.rows.items.map((row) => row.id).toSet().length,
        key.currentState!.rows.items.length,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'collapsed leading group stays anchored while hidden page rows cross the cache limit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, groupsOnly: true));
      await tester.pumpAndSettle();
      final title = find.textContaining('参考汇总');
      final top = tester.getTopLeft(title).dy;
      for (var page = 2; page <= 12; page++) {
        await key.currentState!.rows.loadNextPage();
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(title).dy, closeTo(top, 0.5));
      }
      expect(key.currentState!.requested.last, 12);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'one-row pages continue filling a large viewport beyond the page window',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key, smallPages: true));
      await tester.pumpAndSettle();
      for (var page = 2; page <= 12; page++) {
        await key.currentState!.rows.loadNextPage();
        await tester.pumpAndSettle();
      }
      expect(key.currentState!.requested.last, 12);
      expect(
        key.currentState!.rows.items.map((row) => row.id).toSet(),
        hasLength(12),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long paging evicts distant rows, retains selection and clears the old query',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      key.currentState!.selectFirst();
      await tester.pump();
      for (var attempt = 0; attempt < 7; attempt++) {
        _body(tester).position.jumpTo(_body(tester).position.maxScrollExtent);
        await tester.pumpAndSettle();
        await key.currentState!.rows.loadNextPage();
        await tester.pumpAndSettle();
      }
      final rows = key.currentState!.rows.items;
      expect(key.currentState!.page, greaterThan(5));
      expect(
        rows.length,
        lessThanOrEqualTo(81),
        reason:
            'window and one incoming/visible boundary plus one explicit selected row',
      );
      expect(rows.where((row) => row.id == 'a-1-0'), hasLength(1));
      expect(rows.map((row) => row.id).toSet().length, rows.length);
      key.currentState!.query();
      await tester.pumpAndSettle();
      expect(
        key.currentState!.rows.items.every((row) => row.id.startsWith('b-')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
