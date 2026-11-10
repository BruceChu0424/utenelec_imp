import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/shared/models/immutable_paged_rows.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';

class _Row {
  const _Row(this.id, this.value);
  final int id;
  final String value;
}

String _key(_Row row) => '${row.id}';
String _value(_Row row) => row.value;
const _columns = [
  MasterColumnDef<_Row>(key: 'value', label: '名称', width: 160, value: _value),
];

Widget _app({
  required List<_Row> rows,
  List<MasterColumnDef<_Row>> columns = _columns,
  MasterDataTableRowsController<_Row>? controller,
  bool immutable = true,
  Object? revision,
  bool Function(_Row)? visible,
  String? Function(_Row)? identity,
  String? Function(_Row)? keyOf = _key,
  Set<String> selected = const {},
  ValueChanged<Set<String>>? onSelected,
  bool serverPaged = false,
  Map<String, List<MasterFacetBucket>> facets = const {},
}) => MaterialApp(
  home: Scaffold(
    body: MasterDataTableView<_Row>(
      items: rows,
      columns: columns,
      immutableRows: immutable,
      presentationRevision: revision,
      rowsController: controller,
      rowVisible: visible,
      rowKeyOf: keyOf,
      idOf: identity,
      selectable: onSelected != null,
      selectedIds: selected,
      onSelectedIdsChanged: onSelected,
      virtualized: true,
      facets: facets,
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      onPageChange: serverPaged ? (_) {} : null,
      showFullscreenToggle: false,
    ),
  ),
);

void main() {
  for (final total in [35000, 100000]) {
    testWidgets(
      '$total progressive rows prepare each immutable identity and window slot once',
      (tester) async {
        final builder = ImmutablePagedRowsBuilder<_Row>();
        final session = PagedReadWindowSession<_Row>(isCurrent: () => true);
        final controller = MasterDataTableRowsController<_Row>();
        final revision = Object();
        const columns = [
          MasterColumnDef<_Row>(
            key: 'value',
            label: '名称',
            width: 160,
            value: _value,
            filterFromRows: true,
          ),
        ];
        var collected = 0;
        var facetRows = 0;
        var facetSorts = 0;
        var windowRows = 0, rowPlanRows = 0, textKeys = 0, selectionIds = 0;
        var retainedRows = 0, retainedSlots = 0, retainedText = 0;
        debugMasterTableWorkObserver = (label, count) {
          if (label == 'collectRows') collected += count;
          if (label == 'facetRows') facetRows += count;
          if (label == 'facetSortValues') facetSorts++;
          if (label == 'windowSlotRows') windowRows += count;
          if (label == 'rowPlanRows') rowPlanRows += count;
          if (label == 'selectionRowKeys') textKeys += count;
          if (label == 'selectionIds') selectionIds += count;
          if (label == 'flatWindowRetainedRows') retainedRows = count;
          if (label == 'flatWindowRetainedSlots') retainedSlots = count;
          if (label == 'textSnapshotRetainedRows') retainedText = count;
        };
        addTearDown(() => debugMasterTableWorkObserver = null);
        List<_Row>? first;
        late List<_Row> latest;
        while (builder.length < total) {
          final end = builder.length == 0
              ? 50
              : (builder.length + 1000).clamp(0, total);
          while (builder.length < end) {
            builder.add(_Row(builder.length, '同一展示值'));
          }
          final rows = builder.snapshot();
          first ??= rows;
          final page = session.bindResult(
            PagedResult<_Row>(
              items: rows,
              page: 1,
              size: rows.length,
              total: total,
              totalPages: 1,
            ),
            pending: rows.length < total,
            growing: rows.length < total,
          );
          latest = page.items;
          await tester.pumpWidget(
            _app(
              rows: page.items,
              controller: controller,
              columns: columns,
              revision: revision,
              identity: _key,
              onSelected: (_) {},
            ),
          );
          await tester.pump(const Duration(milliseconds: 16));
          if (builder.length < total) {
            expect(
              selectionIds,
              0,
              reason:
                  'growing rows with no selection need no header eligibility scan',
            );
          }
        }
        await tester.pumpAndSettle();
        expect(controller.items, hasLength(total));
        expect(controller.items.last.id, total - 1);
        expect(
          collected,
          total,
          reason: 'old prefixes must not rebuild ID sets',
        );
        expect(
          windowRows,
          total,
          reason: 'window slots append only the new segment',
        );
        expect(
          rowPlanRows,
          0,
          reason: 'flat rows already own their display order',
        );
        expect(
          textKeys,
          0,
          reason: 'immutable prefixes prove text selection identity',
        );
        expect(
          selectionIds,
          greaterThanOrEqualTo(total),
          reason:
              'complete selection must still recheck every current eligibility',
        );
        expect(
          facetRows,
          total,
          reason: 'local facets count only each new segment',
        );
        expect(
          facetSorts,
          1,
          reason: 'partial prefixes never sort incomplete buckets',
        );
        await tester.tap(find.text('名称').first);
        await tester.pumpAndSettle();
        expect(find.text('同一展示值 ($total)'), findsOneWidget);
        await tester.tapAt(const Offset(760, 550));
        await tester.pumpAndSettle();
        expect(
          first,
          hasLength(50),
          reason: 'earlier published membership is frozen',
        );
        expect(
          () => controller.items.add(const _Row(-1, 'invalid')),
          throwsUnsupportedError,
        );
        expect(
          (retainedRows, retainedSlots, retainedText),
          (total, total, total),
        );
        // Entering mutable editing releases fast-only roots while the original
        // DTOs and generic row-keyed editor slots remain available to the owner.
        await tester.pumpWidget(
          _app(
            rows: latest,
            controller: controller,
            columns: columns,
            revision: revision,
            immutable: false,
          ),
        );
        await tester.pumpAndSettle();
        expect((retainedRows, retainedSlots, retainedText), (0, 0, 0));
        expect(controller.items, hasLength(total));
        await tester.pumpWidget(
          _app(
            rows: latest,
            controller: controller,
            columns: columns,
            revision: revision,
            visible: (_) => true,
          ),
        );
        await tester.pumpAndSettle();
        expect((retainedRows, retainedSlots, retainedText), (0, 0, 0));
        await tester.pumpWidget(
          _app(
            rows: latest,
            controller: controller,
            columns: columns,
            revision: revision,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          (retainedRows, retainedSlots, retainedText),
          (total, total, total),
        );
        session.invalidate();
        await tester.pumpWidget(_app(rows: latest, controller: controller));
        await tester.pumpAndSettle();
        expect(controller.items, isEmpty);
        expect((retainedRows, retainedSlots, retainedText), (0, 0, 0));
        final nextOwner = PagedReadWindowSession<_Row>(isCurrent: () => true);
        latest = nextOwner
            .bindResult(
              PagedResult<_Row>(
                items: builder.snapshot(),
                page: 1,
                size: total,
                total: total,
                totalPages: 1,
              ),
            )
            .items;
        await tester.pumpWidget(
          _app(
            rows: latest,
            controller: controller,
            columns: columns,
            revision: revision,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          (retainedRows, retainedSlots, retainedText),
          (total, total, total),
        );
        expect(controller.items, hasLength(total));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'duplicate presentation keys retain last-value first-position merge',
    (tester) async {
      final builder = ImmutablePagedRowsBuilder<_Row>()
        ..add(const _Row(1, '原值'));
      final controller = MasterDataTableRowsController<_Row>();
      await tester.pumpWidget(
        _app(rows: builder.snapshot(), controller: controller),
      );
      await tester.pumpAndSettle();
      builder.add(const _Row(1, '更新值'));
      builder.add(const _Row(2, '另一行'));
      await tester.pumpWidget(
        _app(rows: builder.snapshot(), controller: controller),
      );
      await tester.pumpAndSettle();
      expect(controller.items.map((row) => row.value), ['更新值', '另一行']);
      builder.add(const _Row(2, '再更新'));
      builder.add(const _Row(3, '第三行'));
      await tester.pumpWidget(
        _app(rows: builder.snapshot(), controller: controller),
      );
      await tester.pumpAndSettle();
      expect(controller.items.map((row) => row.value), ['更新值', '再更新', '第三行']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'row visibility and live eligibility remain current on the same snapshot',
    (tester) async {
      final builder = ImmutablePagedRowsBuilder<_Row>()
        ..add(const _Row(1, '第一行'))
        ..add(const _Row(2, '第二行'));
      final rows = builder.snapshot();
      final controller = MasterDataTableRowsController<_Row>();
      var allow = true;
      var onlyFirst = false;
      bool visible(_Row row) => !onlyFirst || row.id == 1;
      String? eligible(_Row row) => allow ? _key(row) : null;
      Set<String>? selected;
      Widget app() => _app(
        rows: rows,
        controller: controller,
        visible: visible,
        identity: eligible,
        onSelected: (value) => selected = value,
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      allow = false;
      onlyFirst = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(controller.items.map((row) => row.id), [1]);
      await tester.tap(find.byKey(const Key('master-data-table-select-all')));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      allow = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('master-data-table-select-all')));
      await tester.pumpAndSettle();
      expect(selected, {'1'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit presentation revision reuses facets then retires external values',
    (tester) async {
      final builder = ImmutablePagedRowsBuilder<_Row>()
        ..add(const _Row(1, '内容'));
      final rows = builder.snapshot();
      var prefix = '旧';
      Object revision = Object();
      final columns = [
        MasterColumnDef<_Row>(
          key: 'value',
          label: '名称',
          width: 160,
          filterFromRows: true,
          value: (row) => '$prefix${row.value}',
        ),
      ];
      var facetRows = 0;
      debugMasterTableWorkObserver = (label, count) {
        if (label == 'facetRows') facetRows += count;
      };
      addTearDown(() => debugMasterTableWorkObserver = null);
      Widget app() => _app(rows: rows, columns: columns, revision: revision);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final before = facetRows;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(facetRows, before);
      prefix = '新';
      revision = Object();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(facetRows, greaterThan(before));
      await tester.tap(find.text('名称').first);
      await tester.pumpAndSettle();
      expect(find.text('新内容 (1)'), findsOneWidget);
      expect(find.text('旧内容 (1)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden column waits for reveal before scanning row widths', (
    tester,
  ) async {
    var hiddenMeasures = 0;
    final columns = [
      const MasterColumnDef<_Row>(
        key: 'value',
        label: '名称',
        width: 160,
        value: _value,
      ),
      MasterColumnDef<_Row>(
        key: 'hidden',
        label: '附注',
        width: 160,
        defaultVisible: false,
        value: _value,
        measureValueOf: (row) {
          hiddenMeasures++;
          return row.value;
        },
      ),
    ];
    final builder = ImmutablePagedRowsBuilder<_Row>();
    for (var i = 0; i < 1000; i++) {
      builder.add(_Row(i, '值$i'));
    }
    await tester.pumpWidget(_app(rows: builder.snapshot(), columns: columns));
    await tester.pumpAndSettle();
    expect(hiddenMeasures, 0);
    await tester.tap(find.text('表头设置 1/2'));
    await tester.pumpAndSettle();
    final chooser = find.byKey(const ValueKey('uten-column-chooser-scroll'));
    await tester.tap(find.descendant(of: chooser, matching: find.text('附注')));
    await tester.pumpAndSettle();
    expect(hiddenMeasures, 1000);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'non-empty local sort and filter do not repeat on stable host rebuilds',
    (tester) async {
      final builder = ImmutablePagedRowsBuilder<_Row>();
      for (var i = 0; i < 600; i++) {
        builder.add(_Row(i, '${600 - i}'));
      }
      final rows = builder.snapshot();
      final revision = Object();
      const columns = [
        MasterColumnDef<_Row>(
          key: 'value',
          label: '数量',
          width: 160,
          type: 'number',
          sortable: true,
          filterFromRows: true,
          value: _value,
        ),
      ];
      var sorts = 0, projections = 0;
      debugMasterTableWorkObserver = (label, count) {
        if (label == 'localSortRows') sorts++;
        if (label == 'projectionRows') projections++;
      };
      addTearDown(() => debugMasterTableWorkObserver = null);
      Widget app() => _app(rows: rows, columns: columns, revision: revision);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('数量').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('从小到大'));
      await tester.pumpAndSettle();
      expect(sorts, 1);
      expect(
        tester.getTopLeft(find.text('1')).dy,
        lessThan(tester.getTopLeft(find.text('2')).dy),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(sorts, 1);
      await tester.tap(find.text('数量').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 (1)'));
      await tester.pumpAndSettle();
      final before = (sorts, projections);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect((sorts, projections), before);
      expect(find.text('2'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'facet rows release on server mode, column removal and owner retirement',
    (tester) async {
      final builder = ImmutablePagedRowsBuilder<_Row>();
      for (var i = 0; i < 1000; i++) {
        builder.add(_Row(i, '值$i'));
      }
      final raw = builder.snapshot();
      final session = PagedReadWindowSession<_Row>(isCurrent: () => true);
      List<_Row> bind(PagedReadWindowSession<_Row> owner) => owner
          .bindResult(
            PagedResult<_Row>(
              items: freezePagedRows(raw),
              page: 1,
              size: 1000,
              total: 1000,
              totalPages: 1,
            ),
          )
          .items;
      var rows = bind(session);
      final revision = Object();
      const localColumns = [
        MasterColumnDef<_Row>(
          key: 'value',
          label: '名称',
          width: 160,
          value: _value,
          filterFromRows: true,
        ),
      ];
      var retained = -1;
      debugMasterTableWorkObserver = (label, count) {
        if (label == 'facetRetainedRows') retained = count;
      };
      addTearDown(() => debugMasterTableWorkObserver = null);
      Future<void> local() async {
        await tester.pumpWidget(
          _app(rows: rows, columns: localColumns, revision: revision),
        );
        await tester.pumpAndSettle();
        expect(retained, 1000);
      }

      await local();
      await tester.pumpWidget(
        _app(
          rows: rows,
          columns: localColumns,
          revision: revision,
          serverPaged: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(retained, 0);
      await local();
      await tester.pumpWidget(
        _app(
          rows: rows,
          columns: localColumns,
          revision: revision,
          facets: const {
            'value': [MasterFacetBucket(value: '服务端', count: 1000)],
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(retained, 0);
      await local();
      await tester.pumpWidget(_app(rows: rows, revision: revision));
      await tester.pumpAndSettle();
      expect(retained, 0);
      await local();
      session.invalidate();
      await tester.pumpWidget(
        _app(rows: rows, columns: localColumns, revision: revision),
      );
      await tester.pumpAndSettle();
      expect(retained, 0);
      final nextOwner = PagedReadWindowSession<_Row>(isCurrent: () => true);
      rows = bind(nextOwner);
      await local();
      expect(tester.takeException(), isNull);
    },
  );
}
