import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

/// 2026-11-10 阶段 6 调查钉死：若干宿主（FQC 处置、生产物料发现两页、委外发现申请）
/// 传入可变行对象并在原地改字段后重建。身份稳定合并（a32dadda7）在「相同实例+相同
/// 顺序」时保留输出列表对象与行计划缓存——它只省掉重新分配，绝不跳过表格 build：
/// 单元格 getter 每次 build 重新求值，原地改动必须照常显示。此测试把该合同钉死，
/// 防止未来有人把「保身份」优化成「保渲染结果」。
/// A plain mutable row: field assignments after the table already shows it.
/// No operator== — identity, exactly like FqcReportRow / DiscoveryMaterialRow.
class _MutableRow {
  _MutableRow(this.state, this.name);
  String state;
  final String name;
}

void main() {
  Widget host(List<_MutableRow> items) => MaterialApp(
    home: Scaffold(
      body: SelectionArea(
        child: MasterDataTableView<_MutableRow>(
          columns: [
            MasterColumnDef(
              key: 'state',
              label: '状态',
              width: 220,
              value: (row) => row.state,
            ),
            MasterColumnDef(
              key: 'name',
              label: '名称',
              width: 220,
              value: (row) => row.name,
            ),
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          rowKeyOf: (row) => row.name,
        ),
      ),
    ),
  );

  testWidgets(
    'in-place field mutation re-renders cells on a same-instance rebuild',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = [_MutableRow('未提交', 'row-a'), _MutableRow('未提交', 'row-b')];
      // Fresh wrapper list each rebuild, same instances in the same order —
      // exactly what `.where(...).toList()` / `List.unmodifiable(...)` hosts do.
      await tester.pumpWidget(host(List.unmodifiable(rows)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('未提交'), findsNWidgets(2));

      rows.first.state = '已确认';
      await tester.pumpWidget(host(List.unmodifiable(rows)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('已确认'), findsOneWidget);
      expect(find.text('未提交'), findsNWidgets(1));

      // Mutating again without even replacing the wrapper list must also show.
      rows.last.state = '已驳回';
      await tester.pumpWidget(host(List.unmodifiable(rows)));
      await tester.pumpAndSettle();
      expect(find.text('已驳回'), findsOneWidget);
      expect(find.text('未提交'), findsNothing);
    },
  );

  testWidgets(
    'mutation on the same wrapper list instance still re-renders cells',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final rows = [_MutableRow('草稿', 'row-c')];
      await tester.pumpWidget(host(rows));
      await tester.pumpAndSettle();
      expect(find.text('草稿'), findsOneWidget);

      rows.first.state = '已过账';
      // Same list instance passed again: the merge trivially keeps it; the
      // rebuild must still re-read the mutated field.
      await tester.pumpWidget(host(rows));
      await tester.pumpAndSettle();
      expect(find.text('已过账'), findsOneWidget);
      expect(find.text('草稿'), findsNothing);
    },
  );
}
