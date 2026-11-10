// 列宽扫描的按列游标(2026-11-10 性能根治 E 项)：
// 1) 逐批追加/同实例静默重拉只访问新增行——已测前缀不重新取值不重新排版；
// 2) 前缀实例漂移(换查询重拉)重走全部行,但已见值串零排版(去重兜底)；
// 3) 平台扩展值逐批到达只重走平台列——业务列取值次数恒等于行数,不随批数放大。
// 计数与机器负载无关；extractor 调用数代表"访问过的格",排版数代表 TextPainter 工作。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/immutable_paged_rows.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

class _Row {
  const _Row(this.id, this.value);
  final String id;
  final String value;
}

String? _value(_Row row) => row.value;

Widget _plainTable(
  List<_Row> items,
  String? Function(_Row) measure, {
  Object? revision,
}) {
  final column = MasterColumnDef<_Row>(
    key: 'value',
    label: '名称',
    width: 160,
    value: _value,
    measureValueOf: measure,
  );
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 400,
        child: MasterDataTableView<_Row>(
          columns: [column],
          items: items,
          presentationRevision: revision,
          rowKeyOf: (row) => row.id,
          virtualized: true,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          showFullscreenToggle: false,
        ),
      ),
    ),
  );
}

class _Layout extends PlatformTableLayoutNotifier {
  _Layout(super.tableKey);
  @override
  PlatformTableLayout build() => PlatformTableLayout();
  @override
  void persist() {}
}

/// 每批携带内嵌 definition 与当批各行的扩展值(值随批到达,模拟逐批交付)。
class _ValuesRepository extends PlatformTableRepository {
  _ValuesRepository() : super(ApiClient(Dio()));
  int inFlight = 0;
  Duration latency = const Duration(milliseconds: 100);
  final Set<String> served = {};

  @override
  Future<List<PlatformTableCapabilities>> scopes() async => const [
    PlatformTableCapabilities(scope: 'perf', supportsValues: true),
  ];

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
    inFlight++;
    try {
      await Future<void>.delayed(latency);
    } finally {
      inFlight--;
    }
    served.addAll(ids);
    const definition = PlatformColumnDefinition(
      id: 'ext',
      scope: 'perf',
      name: '扩展',
    );
    return [
      for (final id in ids)
        PlatformRowValues(
          recordId: id,
          version: 1,
          cells: [
            PlatformColumnCell(
              columnId: 'ext',
              value: '扩展值-$id',
              definition: definition,
            ),
          ],
        ),
    ];
  }
}

Widget _platformHost(Widget child, _ValuesRepository repo) => ProviderScope(
  overrides: [
    platformTableRepositoryProvider.overrideWithValue(repo),
    platformTableLayoutProvider('perf.width').overrideWith(
      () => _Layout('perf.width'),
    ),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  testWidgets('同实例静默重拉: 已测前缀零取值零排版(值集超上限清空后亦然)', (tester) async {
    var calls = 0;
    String? measure(_Row row) {
      calls++;
      return row.value;
    }
    // 4500 个唯一值: 量宽去重集超过 4000 上限被清空过,游标仍是唯一正确性依据。
    final rows = List.generate(4500, (i) => _Row('id-$i', '唯一值$i'));
    await tester.pumpWidget(_plainTable(rows, measure));
    await tester.pumpAndSettle();
    expect(calls, 4500);

    final beforeCalls = calls;
    final beforeShapes = debugMasterTableMeasureTextCount;
    await tester.pumpWidget(_plainTable(List.of(rows), measure));
    await tester.pumpAndSettle();
    expect(calls, beforeCalls, reason: '同一批行实例换个 List: 前缀不重走');
    expect(
      debugMasterTableMeasureTextCount,
      beforeShapes,
      reason: '去重集被上限清空后也不重新排版',
    );
  });

  testWidgets('追加只访问新增行; 换新实例(同值串)重走但零排版', (tester) async {
    var calls = 0;
    String? measure(_Row row) {
      calls++;
      return row.value;
    }
    final base = List.generate(10, (i) => _Row('id-$i', '值$i'));
    await tester.pumpWidget(_plainTable(base, measure));
    await tester.pumpAndSettle();
    expect(calls, 10);

    // 追加: 前缀锚点校验通过,只取值新增行。
    final appended = [...base, for (var i = 10; i < 20; i++) _Row('id-$i', '值$i')];
    await tester.pumpWidget(_plainTable(appended, measure));
    await tester.pumpAndSettle();
    expect(calls, 20, reason: '追加只访问 10 个新增格');

    // 换新实例(同值串): 前缀漂移重走全部行,但值串去重吸收,零排版。
    final beforeShapes = debugMasterTableMeasureTextCount;
    final reslung = [for (final row in appended) _Row(row.id, row.value)];
    await tester.pumpWidget(_plainTable(reslung, measure));
    await tester.pumpAndSettle();
    expect(calls, 40, reason: '前缀漂移重走全部行');
    expect(
      debugMasterTableMeasureTextCount,
      beforeShapes,
      reason: '已知值串不重新排版',
    );
  });

  testWidgets('平台扩展值逐批到达: 业务列取值恒等于行数, 平台值全部量到', (tester) async {
    final repo = _ValuesRepository();
    const total = 1050;
    final builder = ImmutablePagedRowsBuilder<_Row>();
    final session = PagedReadWindowSession<_Row>(isCurrent: () => true);
    var businessCalls = 0;
    final revision = Object();
    Widget tableFor(List<_Row> rows, Object rev) => MasterDataTableView<_Row>(
      items: rows,
      columns: [
        MasterColumnDef<_Row>(
          key: 'value',
          label: '名称',
          width: 160,
          value: _value,
          measureValueOf: (row) {
            businessCalls++;
            return row.value;
          },
        ),
      ],
      immutableRows: true,
      presentationRevision: rev,
      rowKeyOf: (row) => row.id,
      idOf: (row) => row.id,
      virtualized: true,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      showFullscreenToggle: false,
      platformBinding: PlatformTableBinding<_Row>(
        tableKey: 'perf.width',
        scope: 'perf',
        recordIdOf: (row) => row.id,
      ),
      tableKey: 'perf.width',
    );
    final steps = [50, 550, total];
    for (final end in steps) {
      while (builder.length < end) {
        builder.add(_Row('id-${builder.length}', '业务值${builder.length}'));
      }
      final page = session.bindResult(
        PagedResult<_Row>(
          items: builder.snapshot(),
          page: 1,
          size: end,
          total: total,
          totalPages: 1,
        ),
        pending: end < total,
        growing: end < total,
      );
      await tester.pumpWidget(_platformHost(tableFor(page.items, revision), repo));
      for (var i = 0; i < 20 && repo.inFlight > 0; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    for (var i = 0; i < 20 && repo.inFlight > 0; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(repo.served.length, total, reason: '每行扩展值都送达');
    expect(
      businessCalls,
      total,
      reason: '平台值到达只重走平台列: 业务列每格恰好取值一次,不随批数放大',
    );
  });
}
