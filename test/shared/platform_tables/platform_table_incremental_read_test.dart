import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/master_data_table_rows_controller.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/immutable_paged_rows.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

// 结构基线/修复对照：以计数器量化扩展字段读取的重复请求、每重建的
// 记录号求值与量宽重启。与真机时序无关，不做毫秒性能承诺。

class _Row {
  const _Row(this.id, this.value);
  final String id;
  final String value;
}

class _Layout extends PlatformTableLayoutNotifier {
  _Layout(super.tableKey);
  @override
  PlatformTableLayout build() => PlatformTableLayout();
  @override
  void persist() {}
}

class _CountingRepository extends PlatformTableRepository {
  _CountingRepository() : super(ApiClient(Dio()));
  final batches = <List<String>>[];
  int inFlight = 0;
  int peakInFlight = 0;
  int scopeReads = 0;
  Duration latency = const Duration(milliseconds: 400);
  final Set<String> served = {};

  @override
  Future<List<PlatformTableCapabilities>> scopes() async {
    scopeReads++;
    return const [
      PlatformTableCapabilities(scope: 'perf', supportsValues: true),
    ];
  }

  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async => const [];

  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    batches.add(List.of(ids));
    inFlight++;
    peakInFlight = math.max(peakInFlight, inFlight);
    try {
      await Future<void>.delayed(latency);
    } finally {
      inFlight--;
    }
    served.addAll(ids);
    return [
      for (final id in ids) PlatformRowValues(recordId: id, version: 1),
    ];
  }
}

const _columns = [
  MasterColumnDef<_Row>(key: 'value', label: '名称', width: 160, value: _value),
];
String? _value(_Row row) => row.value;

Widget _host(
  Widget child, {
  required _CountingRepository repo,
}) => ProviderScope(
  overrides: [
    platformTableRepositoryProvider.overrideWithValue(repo),
    platformTableLayoutProvider('perf.table').overrideWith(
      () => _Layout('perf.table'),
    ),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

Widget _table({
  required List<_Row> rows,
  required PlatformTableBinding<_Row> binding,
  List<MasterDataGroup<_Row>> leadingGroups = const [],
  Set<String> selected = const {},
  ValueChanged<Set<String>>? onSelected,
  Object? revision,
  MasterDataTableRowsController<_Row>? controller,
}) => MasterDataTableView<_Row>(
  items: rows,
  columns: _columns,
  immutableRows: true,
  presentationRevision: revision,
  rowKeyOf: (row) => row.id,
  idOf: (row) => row.id,
  leadingGroups: leadingGroups,
  selectable: onSelected != null,
  selectedIds: selected,
  onSelectedIdsChanged: onSelected,
  virtualized: true,
  rowsController: controller,
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
  showFullscreenToggle: false,
  platformBinding: binding,
  tableKey: 'perf.table',
);

PlatformTableBinding<_Row> _binding(void Function() onRecordId) =>
    PlatformTableBinding<_Row>(
      tableKey: 'perf.table',
      scope: 'perf',
      recordIdOf: (row) {
        onRecordId();
        return row.id;
      },
    );

Future<void> _drain(WidgetTester tester, _CountingRepository repo) async {
  // 每批 200 条、延迟 400ms：把最多 40 批排空（虚拟时钟推进）。
  for (var i = 0; i < 60 && repo.inFlight > 0; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pump(const Duration(milliseconds: 50));
}

Map<String, Object> _metrics(_CountingRepository repo, int recordIdCalls) {
  final requested = <String>[];
  for (final batch in repo.batches) {
    requested.addAll(batch);
  }
  final counts = <String, int>{};
  for (final batch in repo.batches) {
    final key = batch.length == 200 ? batch.first : 'n${batch.length}:${batch.first}';
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final firstBatch = repo.batches.isEmpty ? null : repo.batches.first;
  final firstRepeats = firstBatch == null
      ? 0
      : repo.batches
            .where((b) => b.length == firstBatch.length && b.first == firstBatch.first)
            .length;
  return {
    'requests': repo.batches.length,
    'idsRequested': requested.length,
    'uniqueIds': requested.toSet().length,
    'firstBatchRepeats': firstRepeats,
    'peakInFlight': repo.peakInFlight,
    'scopeReads': repo.scopeReads,
    'recordIdCalls': recordIdCalls,
  };
}

void main() {
  testWidgets('progressive growth reads extension values once per record', (
    tester,
  ) async {
    final repo = _CountingRepository();
    var recordIdCalls = 0;
    final binding = _binding(() => recordIdCalls++);
    final builder = ImmutablePagedRowsBuilder<_Row>();
    final session = PagedReadWindowSession<_Row>(isCurrent: () => true);
    const total = 3000;
    final revision = Object();
    List<_Row>? latest;
    while (builder.length < total) {
      final end = builder.length == 0
          ? 50
          : (builder.length + 1000).clamp(0, total);
      while (builder.length < end) {
        builder.add(_Row('id-${builder.length}', 'v${builder.length}'));
      }
      final rows = builder.snapshot();
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
        _host(
          _table(rows: page.items, binding: binding, revision: revision),
          repo: repo,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    await _drain(tester, repo);
    final metrics = _metrics(repo, recordIdCalls);
    // ignore: avoid_print
    print('perfMetrics $metrics');
    expect(repo.served, containsAll(['id-0', 'id-${total - 1}']));
    expect(metrics['idsRequested'], metrics['uniqueIds'],
        reason: 'progressive growth must request each record id exactly once');
    expect(metrics['peakInFlight'], 1,
        reason: 'one reader per table; a retired pass must cancel transport');
    expect(metrics['scopeReads'], 1,
        reason: 'scope metadata is shared and read once');
    expect(metrics['firstBatchRepeats'], 1,
        reason: 'a longer prefix never restarts the read from record zero');
  });

  testWidgets('parent rebuilds on a stable list do not re-read record ids', (
    tester,
  ) async {
    final repo = _CountingRepository();
    var recordIdCalls = 0;
    final binding = _binding(() => recordIdCalls++);
    const total = 3000;
    final rows = List.generate(total, (i) => _Row('id-$i', 'v$i'));
    var selected = <String>{};
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => _table(
            rows: rows,
            binding: binding,
            selected: selected,
            onSelected: (next) => setState(() => selected = next),
          ),
        ),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();
    final before = (recordIdCalls, repo.batches.length);
    for (var i = 0; i < 3; i++) {
      selected = {'id-$i'};
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => _table(
              rows: rows,
              binding: binding,
              selected: selected,
              onSelected: (next) => setState(() => selected = next),
            ),
          ),
          repo: repo,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    await _drain(tester, repo);
    final metrics = _metrics(repo, recordIdCalls);
    // ignore: avoid_print
    print('perfMetrics $metrics before=$before');
    expect(metrics['idsRequested'], metrics['uniqueIds'],
        reason: 'selection rebuilds must not re-read any record id');
    expect(metrics['peakInFlight'], 1);
  });

  testWidgets('a rebuilt leading-groups list does not restart the value read', (
    tester,
  ) async {
    final repo = _CountingRepository();
    var recordIdCalls = 0;
    final binding = _binding(() => recordIdCalls++);
    const total = 3000;
    final rows = List.generate(total, (i) => _Row('id-$i', 'v$i'));
    final groups = [
      MasterDataGroup<_Row>(
        id: 'disabled',
        title: '禁用($total)',
        items: List.generate(200, (i) => _Row('g-$i', 'g$i')),
      ),
    ];
    await tester.pumpWidget(
      _host(
        _table(rows: rows, binding: binding, leadingGroups: groups),
        repo: repo,
      ),
    );
    await tester.pumpAndSettle();
    final before = repo.batches.length;
    // 宿主重导出同等内容的新分组列表（错误态/每次 build 新列表的真实形态）。
    for (var round = 0; round < 3; round++) {
      await tester.pumpWidget(
        _host(
          _table(
            rows: rows,
            binding: binding,
            leadingGroups: [
              MasterDataGroup<_Row>(
                id: 'disabled',
                title: '禁用($total)',
                items: groups.first.items,
              ),
            ],
          ),
          repo: repo,
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    await _drain(tester, repo);
    final metrics = _metrics(repo, recordIdCalls);
    // ignore: avoid_print
    print('perfMetrics $metrics beforeRequests=$before');
    expect(metrics['idsRequested'], metrics['uniqueIds'],
        reason: 'a rebuilt group list with the same items re-reads nothing');
    expect(metrics['uniqueIds'], total + 200);
    expect(metrics['peakInFlight'], 1);
  });

  testWidgets('pure parent rebuilds re-collect no rows and rebuild no plan', (
    tester,
  ) async {
    final repo = _CountingRepository();
    var recordIdCalls = 0;
    final binding = _binding(() => recordIdCalls++);
    const total = 3000;
    final rows = List.generate(total, (i) => _Row('id-$i', 'v$i'));
    final groupItems = List.generate(200, (i) => _Row('g-$i', 'g$i'));
    List<MasterDataGroup<_Row>> groups() => [
      MasterDataGroup<_Row>(id: 'disabled', title: '禁用', items: groupItems),
    ];
    var collected = 0;
    var rowPlanRows = 0;
    debugMasterTableWorkObserver = (label, count) {
      if (label == 'collectRows') collected += count;
      if (label == 'rowPlanRows') rowPlanRows += count;
    };
    addTearDown(() => debugMasterTableWorkObserver = null);
    var selected = <String>{};
    final rowController = MasterDataTableRowsController<_Row>();
    Future<void> mount() => tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => _table(
            // 宿主每次 build 都新建列表与闭包（同一批行实例）。
            rows: List.of(rows),
            binding: binding,
            leadingGroups: groups(),
            selected: selected,
            onSelected: (next) => setState(() => selected = next),
            controller: rowController,
          ),
        ),
        repo: repo,
      ),
    );

    await mount();
    await tester.pumpAndSettle();
    final planAfterFirst = rowPlanRows;
    final itemsAfterFirst = rowController.items;
    expect(
      planAfterFirst,
      total,
      reason: 'the first build allocates a plan entry per displayed row',
    );
    for (var round = 0; round < 3; round++) {
      selected = {'id-$round'};
      await mount();
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
      rowPlanRows,
      planAfterFirst,
      reason: 'a pure selection rebuild allocates no row-plan entries',
    );
    expect(
      identical(rowController.items, itemsAfterFirst),
      isTrue,
      reason: 'a merge of the same instances keeps the stable list identity',
    );
    await _drain(tester, repo);
    await tester.pumpAndSettle();
  });
}
