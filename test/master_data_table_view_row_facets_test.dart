// filterFromRows 本地取值筛选 + 本地排序（2026-09-25 全站单号列统一）。
//
// 覆盖：①本地筛选桶从当前行构建（无服务端 facets 也能筛），选中后只显示命中行、
// 「所有」复原；②宿主未接 onSortChange 时 sortable 列就地排序（升降序/取消排序），
// 空值「—」恒排末尾；③筛选把行滤空时空态出现（2026-09-28 起无「清除筛选」按钮，
// 只报筛选生效数）；④「取消排序」位于菜单最上（用户口径）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.billNo, this.name);
  final String billNo;
  final String name;
}

const _rows = <_Row>[
  _Row('XD20260926000002', 'B 货'),
  _Row('XD20260926000001', 'A 货'),
  _Row('—', '无单号行'),
];

Widget _table({void Function(String?, bool)? onSortChange}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 900,
        child: MasterDataTableView<_Row>(
          columns: [
            MasterColumnDef<_Row>(
              key: 'billNo',
              label: '单据号',
              width: 220,
              sortable: true,
              filterFromRows: true,
              value: (r) => r.billNo,
            ),
            MasterColumnDef<_Row>(
              key: 'name',
              label: '名称',
              width: 160,
              value: (r) => r.name,
            ),
          ],
          items: _rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onSortChange: onSortChange,
          embedded: true,
        ),
      ),
    ),
  );
}

/// 打开单据号列的筛选菜单。选中筛选值后表头显示所选值/「单据号：空」
/// （不再显示列名），按需传入当前表头文案；表头在控件树中先于表体行，
/// 与行内同名单号文本重名时取 .first。
Future<void> _openMenu(WidgetTester tester, {String header = '单据号'}) async {
  await tester.tap(find.text(header).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('filterFromRows builds local buckets and filters rows', (
    tester,
  ) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    await _openMenu(tester);
    // 桶来自当前行：两个单号值 + 「其他 (1)」（空占位「—」落其他桶）；「所有」居首。
    expect(find.text('所有'), findsOneWidget);
    expect(find.text('XD20260926000001 (1)'), findsOneWidget);
    expect(find.text('XD20260926000002 (1)'), findsOneWidget);
    expect(find.text('其他 (1)'), findsOneWidget);

    await tester.tap(find.text('XD20260926000001 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('A 货'), findsOneWidget);
    expect(find.text('B 货'), findsNothing);

    // 「其他」桶：只看单号为空的行。
    await _openMenu(tester, header: 'XD20260926000001');
    await tester.tap(find.text('其他 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('无单号行'), findsOneWidget);
    expect(find.text('A 货'), findsNothing);

    // 「所有」复原全部行。
    await _openMenu(tester, header: '单据号：空');
    await tester.tap(find.text('所有'));
    await tester.pumpAndSettle();
    expect(find.text('A 货'), findsOneWidget);
    expect(find.text('B 货'), findsOneWidget);
    expect(find.text('无单号行'), findsOneWidget);
  });

  testWidgets('local sort without onSortChange, cancel sort on top', (
    tester,
  ) async {
    await tester.pumpWidget(_table());
    await tester.pumpAndSettle();

    await _openMenu(tester);
    // 用户口径：「取消排序」在菜单最上面，升降序跟后。
    final cancel = find.text('取消排序');
    final asc = find.text('从小到大');
    expect(cancel, findsOneWidget);
    expect(asc, findsOneWidget);
    expect(tester.getTopLeft(cancel).dy, lessThan(tester.getTopLeft(asc).dy));

    await tester.tap(asc);
    await tester.pumpAndSettle();
    // 升序：000001 在 000002 前；空值「—」恒排末尾（无单号行最后）。
    expect(
      tester.getTopLeft(find.text('A 货')).dy,
      lessThan(tester.getTopLeft(find.text('B 货')).dy),
    );
    expect(
      tester.getTopLeft(find.text('B 货')).dy,
      lessThan(tester.getTopLeft(find.text('无单号行')).dy),
    );

    await _openMenu(tester);
    await tester.tap(find.text('从大到小'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('B 货')).dy,
      lessThan(tester.getTopLeft(find.text('A 货')).dy),
    );
    // 降序时空值仍在末尾。
    expect(
      tester.getTopLeft(find.text('A 货')).dy,
      lessThan(tester.getTopLeft(find.text('无单号行')).dy),
    );

    // 取消排序：回到宿主原始顺序。
    await _openMenu(tester);
    await tester.tap(find.text('取消排序'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('B 货')).dy,
      lessThan(tester.getTopLeft(find.text('A 货')).dy),
    );
  });

  testWidgets('rows filtered to empty: empty state, no clear button', (
    tester,
  ) async {
    // 两列都可本地筛：单据号=000001 且 名称=B 货 → 交叉后 0 行 → 空态。
    // 2026-09-28 用户口径：空态「清除筛选」按钮全站退役——空态只报筛选生效数，
    // 清除入口在表外分段条/行数恢复后的列头控件。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            child: MasterDataTableView<_Row>(
              columns: [
                MasterColumnDef<_Row>(
                  key: 'billNo',
                  label: '单据号',
                  width: 220,
                  filterFromRows: true,
                  value: (r) => r.billNo,
                ),
                MasterColumnDef<_Row>(
                  key: 'name',
                  label: '名称',
                  width: 160,
                  filterFromRows: true,
                  value: (r) => r.name,
                ),
              ],
              items: _rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.text('XD20260926000001 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('A 货'), findsOneWidget);

    await tester.tap(find.text('名称'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B 货 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('A 货'), findsNothing);

    // 空态不再给「清除筛选」按钮，只报两个表头筛选生效。
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsNothing,
    );
    expect(find.text('清除筛选'), findsNothing);
    expect(find.text('当前有 2 个表头筛选生效'), findsOneWidget);
  });

  testWidgets('server facets win over filterFromRows', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            child: MasterDataTableView<_Row>(
              columns: [
                MasterColumnDef<_Row>(
                  key: 'billNo',
                  label: '单据号',
                  width: 220,
                  sortable: true,
                  filterFromRows: true,
                  value: (r) => r.billNo,
                ),
              ],
              items: _rows,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openMenu(tester);
    // 单列表格也照常出桶（列宽测算与渲染不受影响）。
    expect(find.text('所有'), findsOneWidget);
    expect(find.text('XD20260926000001 (1)'), findsOneWidget);
  });
}
