// MasterDataTableView 列宽量宽缓存(ADR-108 / perf-frontend-15):
// 同一份数据换成新的 List 实例(静默重拉)不再重量; 新出现的更长值在帧后补量并只加宽;
// 数据变短列宽不回缩(不跳); 换一套列才全量重算。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

Widget _table(
  List<String> items, {
  String columnKey = 'name',
  double declaredWidth = 60,
  double Function(BuildContext)? minimumWidthOf,
  Widget Function(BuildContext, String)? cellBuilder,
  String? Function(String)? measureValueOf,
  TextScaler textScaler = TextScaler.noScaling,
  bool virtualized = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: Scaffold(
    body: SizedBox(
      width: 900,
      height: 400,
      child: MasterDataTableView<String>(
        virtualized: virtualized,
        columns: [
          MasterColumnDef<String>(
            key: columnKey,
            label: '名称',
            width: declaredWidth,
            minimumWidthOf: minimumWidthOf,
            cellBuilder: cellBuilder,
            measureValueOf: measureValueOf,
            value: (item) => item,
          ),
        ],
        items: items,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        showFullscreenToggle: false,
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'measurement text changes width without changing exact values, local sort/filter or export projection',
    (tester) async {
      final projection = TableColumnProjectionController();
      addTearDown(projection.dispose);
      var calls = 0;
      const unit = 'display-only-wide-unit';
      final column = MasterColumnDef<String>(
        key: 'quantity',
        label: '数量',
        width: 60,
        type: 'number',
        sortable: true,
        filterFromRows: true,
        value: (row) => row,
        exactValueOf: (row) => row,
        measureValueOf: (row) {
          calls++;
          return '$row $unit';
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableColumnProjectionScope(
              controller: projection,
              child: MasterDataTableView<String>(
                tableKey: 'measurement-isolation',
                rowWidgetKeyOf: (row) => ValueKey('measure-row-$row'),
                columns: [column],
                items: const ['10', '2'],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final measured = calls;
      expect(column.value('10'), '10');
      expect(column.exactValueOf!('10'), '10');
      final export = projection.resolve('measurement-isolation')!.toJson();
      expect(export.toString(), isNot(contains(unit)));
      expect(
        projection.resolve('measurement-isolation')!.columns.single.width,
        greaterThan(180),
      );
      expect(
        calls,
        measured,
        reason: 'business and export reads do not invoke measurement',
      );
      expect(find.textContaining(unit), findsNothing);
      await tester.tap(find.text('数量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从小到大'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('2')).dy,
        lessThan(tester.getTopLeft(find.text('10')).dy),
      );
      await tester.tap(find.text('数量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('10'), findsNothing);
      expect(find.byKey(const ValueKey('measure-row-2')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'measurement override still yields between the existing bounded width batches',
    (tester) async {
      var calls = 0;
      final items = [for (var i = 0; i < 1200; i++) '$i'];
      final before = debugMasterTableMeasureTextCount;
      await tester.pumpWidget(
        _table(
          items,
          virtualized: true,
          measureValueOf: (row) {
            calls++;
            return '$row display-unit';
          },
        ),
      );
      expect(calls, lessThan(600));
      expect(debugMasterTableMeasureTextCount - before, lessThan(600));
      await tester.pumpAndSettle();
      expect(calls, greaterThanOrEqualTo(items.length));
      expect(debugMasterTableMeasureTextCount - before, items.length + 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'large snapshots yield between text measurement batches and still fit the last value',
    (tester) async {
      final before = debugMasterTableMeasureTextCount;
      final items = [
        for (var i = 0; i < 1200; i++) '料$i',
        '这是一条位于末尾而且必须完整量宽的货品名称',
      ];
      await tester.pumpWidget(_table(items, virtualized: true));
      expect(
        debugMasterTableMeasureTextCount - before,
        lessThan(600),
        reason: 'the first frame must not shape every loaded value',
      );
      final firstWidth = _columnWidth(tester);
      await tester.pumpAndSettle();
      expect(debugMasterTableMeasureTextCount - before, items.length + 1);
      expect(_columnWidth(tester), greaterThan(firstWidth));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'plain columns fit all loaded values rather than declared width',
    (tester) async {
      await tester.pumpWidget(_table(['短'], declaredWidth: 400));
      await tester.pumpAndSettle();
      final narrow = _columnWidth(tester);
      expect(narrow, lessThan(150));

      const long = 'the widest loaded value is beyond the first thirty rows';
      await tester.pumpWidget(
        _table([...List.filled(30, '短'), long], declaredWidth: 400),
      );
      await tester.pumpAndSettle();
      expect(_columnWidth(tester), greaterThan(narrow));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rich controls retain their fallback or explicit actual minimum',
    (tester) async {
      Widget cell(BuildContext context, String value) => Text(value);
      await tester.pumpWidget(
        _table(['短'], declaredWidth: 240, cellBuilder: cell),
      );
      await tester.pumpAndSettle();
      expect(_columnWidth(tester), 240);

      await tester.pumpWidget(
        _table(
          ['短'],
          columnKey: 'compact',
          declaredWidth: 240,
          cellBuilder: cell,
          minimumWidthOf: (_) => 100,
        ),
      );
      await tester.pumpAndSettle();
      expect(_columnWidth(tester), 100);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nonlinear scaling invalidates widths even when scale(1) is unchanged',
    (tester) async {
      const value = 'A long business value';
      await tester.pumpWidget(
        _table([value], textScaler: const _NonlinearScaler(1)),
      );
      await tester.pumpAndSettle();
      final before = _columnWidth(tester);
      await tester.pumpWidget(
        _table([value], textScaler: const _NonlinearScaler(1.8)),
      );
      await tester.pumpAndSettle();
      expect(_columnWidth(tester), greaterThan(before));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('同一份数据换新 List 实例: 0 次文本测量, 列宽不变', (tester) async {
    await tester.pumpWidget(_table(['甲', '乙乙', '丙丙丙']));
    await tester.pumpAndSettle();
    final before = debugMasterTableMeasureTextCount;
    final widthBefore = _columnWidth(tester);

    await tester.pumpWidget(_table(List.of(['甲', '乙乙', '丙丙丙'])));
    await tester.pumpAndSettle();

    expect(debugMasterTableMeasureTextCount - before, 0);
    expect(_columnWidth(tester), widthBefore);
  });

  testWidgets('新出现更长的值: 帧后只量新值并加宽; 数据变短不回缩', (tester) async {
    await tester.pumpWidget(_table(['短']));
    await tester.pumpAndSettle();
    final narrow = _columnWidth(tester);

    final before = debugMasterTableMeasureTextCount;
    const long = '这是一条明显更长的货品名称用来撑宽列';
    await tester.pumpWidget(_table(['短', long]));
    // 数据到达的这一帧按旧列宽出图(量宽不占这一帧), 帧后补量再加宽。
    expect(_columnWidth(tester), narrow);
    await tester.pumpAndSettle();
    // 只量了新出现的那一个值, 旧值与表头不重量。
    expect(debugMasterTableMeasureTextCount - before, 1);
    final wide = _columnWidth(tester);
    expect(wide, greaterThan(narrow));

    await tester.pumpWidget(_table(['短']));
    await tester.pumpAndSettle();
    expect(_columnWidth(tester), wide);
  });

  testWidgets('换一套列: 全量重算(旧列的量宽不沿用)', (tester) async {
    await tester.pumpWidget(_table(['甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲甲']));
    await tester.pumpAndSettle();
    final wide = _columnWidth(tester);

    await tester.pumpWidget(_table(['甲'], columnKey: 'other'));
    await tester.pumpAndSettle();
    expect(_columnWidth(tester), lessThan(wide));
  });
}

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler(this.factor);
  final double factor;
  @override
  double scale(double fontSize) => fontSize <= 1 ? fontSize : fontSize * factor;
  @override
  double get textScaleFactor => factor;
}

/// 该列表头单元格宽度(列宽由表头与表体共用; 表头格是定宽 Container)。
double _columnWidth(WidgetTester tester) {
  final containers = tester.widgetList<Container>(
    find.ancestor(of: find.text('名称'), matching: find.byType(Container)),
  );
  for (final container in containers) {
    final constraints = container.constraints;
    if (constraints != null &&
        constraints.maxWidth.isFinite &&
        constraints.minWidth == constraints.maxWidth) {
      return constraints.maxWidth;
    }
  }
  fail('没有找到定宽的表头单元格');
}
