// 行首多选列「横滚冻结」回归（UtenFrozenLeadingColumn）。
//
// 用户 2026-09-11 两条反馈，各对一个断言：
// 1.「表格拖动了就不是在最前了，最顶上那个多选框就失灵了，必须拖到最左边才管用」
//    → 横滚后表头全选框仍在视口左缘、且**点得动**；
// 2.「第一列的多选背景颜色要一样，每行之间的分割线也要有」
//    → 行内那份勾选格**不自带底色**（跟整行同底、不遮行底线）；只有横滚后浮上来的
//      副本才自带不透明底 + 右线 + 行底线（它盖在数据格上，不自带就会透）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

void main() {
  const rows = [_Row('a'), _Row('b'), _Row('c')];

  Widget host({
    required Set<String> selected,
    required ValueChanged<Set<String>> onChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 600,
        height: 400,
        child: MasterDataTableView<_Row>(
          columns: [
            for (var i = 0; i < 8; i++)
              MasterColumnDef<_Row>(
                key: 'c$i',
                label: '列$i',
                width: 200,
                value: (item) => '${item.id}-$i',
              ),
          ],
          items: rows,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          selectable: true,
          idOf: (item) => item.id,
          selectedIds: selected,
          onSelectedIdsChanged: onChanged,
        ),
      ),
    ),
  );

  testWidgets('横滚后表头全选框仍在视口左缘且点得动', (tester) async {
    var selected = <String>{};
    await tester.pumpWidget(
      host(selected: selected, onChanged: (next) => selected = next),
    );
    await tester.pumpAndSettle();

    // 未横滚：只有行内原位那一份参与命中，副本被 IgnorePointer 挡掉。
    expect(find.byType(UtenFrozenLeadingColumn), findsWidgets);

    // 往右拖表体，把首列滚出视口。
    await tester.drag(find.text('a-2'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    // 冻结副本顶上来：表头全选框仍可见、且在视口左缘 48px 内。
    final headerChecks = find.byWidgetPredicate(
      (widget) => widget is Checkbox && widget.tristate,
    );
    expect(headerChecks, findsWidgets);
    final visible = headerChecks
        .evaluate()
        .map((element) => element.renderObject as RenderBox)
        .where((box) => box.attached)
        .map((box) => box.localToGlobal(Offset.zero).dx)
        .toList();
    expect(visible.any((dx) => dx < 48), isTrue, reason: '横滚后表头全选框必须仍钉在视口左缘');

    // 点它：整页应被全选（这正是用户说的「失灵」）。
    await tester.tap(headerChecks.last);
    await tester.pumpAndSettle();
    expect(selected, {'a', 'b', 'c'});
  });

  testWidgets('行内勾选格不自带底色，不遮住行底分隔线', (tester) async {
    await tester.pumpWidget(host(selected: const {}, onChanged: (_) {}));
    await tester.pumpAndSettle();

    // 行内那一份勾选格：Checkbox 的最近 DecoratedBox 祖先只画右线，
    // 且其上不能出现 ColoredBox（自带底色 = 盖掉行底线、与行底色不一致）。
    final rowCheckbox = find
        .byWidgetPredicate((widget) => widget is Checkbox && !widget.tristate)
        .first;
    final coloredAncestors = find
        .ancestor(of: rowCheckbox, matching: find.byType(ColoredBox))
        .evaluate()
        .map((element) => element.widget as ColoredBox)
        .toList();
    // 行级底色那层 ColoredBox 仍在（整行同底），但它的宽度是整行——
    // 勾选格自己这 48px 内不得再叠一层不透明底。
    final cellWidth = tester
        .renderObject<RenderBox>(
          find
              .ancestor(of: rowCheckbox, matching: find.byType(DecoratedBox))
              .first,
        )
        .size
        .width;
    expect(cellWidth, lessThanOrEqualTo(48));
    for (final colored in coloredAncestors) {
      final box = tester.renderObject<RenderBox>(find.byWidget(colored));
      expect(box.size.width, greaterThan(48), reason: '勾选格这一层不能自带底色，只有整行那层可以');
    }
  });
}
