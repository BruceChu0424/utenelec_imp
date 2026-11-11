import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

import 'support/table_cell_geometry.dart';
import 'support/pump_until.dart';

class _Layout extends PlatformTableLayoutNotifier {
  _Layout() : super('progressive.layout');
  @override
  PlatformTableLayout build() => const PlatformTableLayout();
}

class _Repository extends PlatformTableRepository {
  _Repository() : super(ApiClient(Dio()));
  Completer<void>? gate;
  int calls = 0;
  String? cell;
  String columnName = '补充资料';
  @override
  Future<List<PlatformTableCapabilities>> scopes() async => const [
    PlatformTableCapabilities(scope: 'resource', priceVisible: true),
  ];
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    calls++;
    await gate?.future;
    return [
      for (final id in ids)
        PlatformRowValues(
          recordId: id,
          version: calls,
          cells: [
            if (cell != null)
              PlatformColumnCell(
                columnId: 'persisted',
                definition: PlatformColumnDefinition(
                  id: 'persisted',
                  scope: scope,
                  name: columnName,
                ),
                value: cell,
              ),
          ],
        ),
    ];
  }
}

class _Harness {
  _Harness({this.freshColumns = false, this.progressive = false});
  final bool progressive;
  final bool freshColumns;
  final repository = _Repository();
  final projection = TableColumnProjectionController();
  final session = PagedReadWindowSession<int>(isCurrent: () => true);
  late StateSetter update;
  late List<int> items = prefix(50);
  String caption = '原值';
  late final columns = [column(caption)];
  static MasterColumnDef<int> column(String caption) => MasterColumnDef<int>(
    key: 'name',
    label: '名称',
    width: 100,
    value: (row) => '$caption$row',
  );

  List<int> prefix(int count) => session
      .bindResult(
        PagedResult<int>(
          items: List.generate(count, (i) => i),
          page: 1,
          size: count,
          total: progressive ? 1626 : count,
          totalPages: 1,
        ),
        pending: progressive && count < 1626,
        growing: progressive && count < 1626,
      )
      .items;

  Widget build() => ProviderScope(
    overrides: [
      platformTableRepositoryProvider.overrideWithValue(repository),
      platformTableLayoutProvider(
        'progressive.layout',
      ).overrideWith(_Layout.new),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: TableColumnProjectionScope(
          controller: projection,
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MasterDataTableView<int>(
                tableKey: 'progressive.layout',
                platformBinding: PlatformTableBinding<int>(
                  tableKey: 'progressive.layout',
                  scope: 'resource',
                  recordIdOf: (row) => '$row',
                ),
                virtualized: true,
                immutableRows: true,
                presentationRevision: caption,
                rowKeyOf: (row) => '$row',
                columns: freshColumns ? [column(caption)] : columns,
                items: items,
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                showFullscreenToggle: false,
              );
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'progressive platform reloads retain columns and scan only appended width cells',
    (tester) async {
      final harness = _Harness(progressive: true);
      addTearDown(harness.projection.dispose);
      await tester.pumpWidget(harness.build());
      // A genuine growing prefix keeps the loading footer animated. Pump its
      // real frames without waiting for that intentionally active animation.
      for (var tick = 0; tick < 24; tick++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      var visited = 0, indexes = 0;
      debugMasterTableWorkObserver = (label, count) {
        if (label == 'widthCells') visited += count;
        if (label == 'visibleColumnIndexes') indexes++;
      };
      addTearDown(() => debugMasterTableWorkObserver = null);
      for (final count in [100, 200, 400, 800, 1626]) {
        harness.update(() => harness.items = harness.prefix(count));
        for (var tick = 0; tick < 24; tick++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      await tester.pumpAndSettle();
      // Current rows and extension cells really loaded; the performance
      // contract must not skip the values endpoint to satisfy this budget.
      expect(harness.repository.calls, greaterThanOrEqualTo(6));
      final table = tester.widget<MasterDataTableView<int>>(
        find.byType(MasterDataTableView<int>),
      );
      expect(table.items, hasLength(1626));
      // ignore: avoid_print
      print(
        'PLATFORM-PREFIX widthCells=$visited expected=1576 indexBuilds=$indexes',
      );
      expect(visited, 1576);
      expect(indexes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fresh same-key column getters retain current closures and widths',
    (tester) async {
      final harness = _Harness(freshColumns: true);
      addTearDown(harness.projection.dispose);
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();
      final before = tableCellWidth(tester, find.text('名称'));
      harness.update(() => harness.caption = '修改后明显更长的值');
      await tester.pumpAndSettle();
      expect(find.text('原值0'), findsNothing);
      expect(find.text('修改后明显更长的值0'), findsOneWidget);
      expect(tableCellWidth(tester, find.text('名称')), greaterThan(before));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real persisted cell and definition updates still publish and fit',
    (tester) async {
      final harness = _Harness();
      addTearDown(harness.projection.dispose);
      harness.repository.cell = '短';
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();
      final before = tableCellWidth(tester, find.text('补充资料'));
      final gate = Completer<void>();
      harness.repository.gate = gate;
      harness.update(() => harness.items = harness.prefix(100));
      await tester.pump();
      harness.repository.cell = '这是真正新返回的补充字段最长值';
      gate.complete();
      await pumpUntil(
        tester,
        () => find.text('这是真正新返回的补充字段最长值').evaluate().isNotEmpty,
        reason: 'the actual new cell must be displayed after the read',
      );
      await tester.pumpAndSettle();
      expect(tableCellWidth(tester, find.text('补充资料')), greaterThan(before));
      harness.repository.columnName = '新定义名称';
      harness.update(() => harness.items = harness.prefix(200));
      await tester.pumpAndSettle();
      expect(find.text('补充资料'), findsNothing);
      expect(find.text('新定义名称'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
