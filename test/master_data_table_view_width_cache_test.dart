// MasterDataTableView 列宽量宽缓存(ADR-108 / perf-frontend-15):
// 同一份数据换成新的 List 实例(静默重拉)不再重量; 新出现的更长值在帧后补量并只加宽;
// 数据变短列宽不回缩(不跳); 换一套列才全量重算。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Widget _table(List<String> items, {String columnKey = 'name'}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 900,
      height: 400,
      child: MasterDataTableView<String>(
        columns: [
          MasterColumnDef<String>(
            key: columnKey,
            label: '名称',
            width: 60,
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
