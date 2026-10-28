import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_tree_view.dart';

List<PaymentStyleNode> _nodes() => [
  PaymentStyleNode(
    id: 'root',
    code: '1',
    name: '分类根',
    children: [
      PaymentStyleNode(id: 'child', code: '2', name: '子分类', children: const []),
    ],
  ),
];

Widget _app(List<PaymentStyleNode> nodes, {int? initialDepth}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 320,
      height: 500,
      child: initialDepth == null
          ? UtenCategoryTreeView<PaymentStyleNode>(nodes: nodes)
          : UtenCategoryTreeView<PaymentStyleNode>(
              nodes: nodes,
              initiallyExpandDepth: initialDepth,
            ),
    ),
  ),
);

void main() {
  test('公共树、分类树和部门树默认全部收起', () {
    expect(
      UtenCategoryTreeView<PaymentStyleNode>(
        nodes: _nodes(),
      ).initiallyExpandDepth,
      0,
    );
    expect(const UtenDepartmentTreeView(nodes: []).initiallyExpandDepth, 0);
    expect(
      UtenHierarchyTreeView<PaymentStyleNode>(
        nodes: _nodes(),
        searchHint: '搜索',
        emptyNoun: '分类',
      ).initiallyExpandDepth,
      0,
    );
  });

  testWidgets('首次进入收起，手动展开后刷新保留，再次进入仍收起', (tester) async {
    await tester.pumpWidget(_app(_nodes()));
    await tester.pumpAndSettle();
    expect(find.text('分类根'), findsOneWidget);
    expect(find.text('子分类'), findsNothing);
    await tester.tap(find.byTooltip('展开分类根'));
    await tester.pumpAndSettle();
    expect(find.text('子分类'), findsOneWidget);
    await tester.pumpWidget(_app(_nodes()));
    await tester.pumpAndSettle();
    expect(find.text('子分类'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(_nodes()));
    await tester.pumpAndSettle();
    expect(find.text('子分类'), findsNothing);
  });

  testWidgets('有显式初始展开的调用也不能在刷新时重开手动收起分支', (tester) async {
    await tester.pumpWidget(_app(_nodes(), initialDepth: 1));
    await tester.pumpAndSettle();
    expect(find.text('子分类'), findsOneWidget);
    await tester.tap(find.byTooltip('收起分类根'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(_nodes(), initialDepth: 1));
    await tester.pumpAndSettle();
    expect(find.text('子分类'), findsNothing);
  });

  testWidgets('搜索临时展开命中路径，清空搜索后恢复收起', (tester) async {
    await tester.pumpWidget(_app(_nodes()));
    await tester.pumpAndSettle();
    final search = find.byType(EditableText).first;
    await tester.enterText(search, '子分类');
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == '子分类',
      ),
      findsOneWidget,
    );
    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(find.text('子分类'), findsNothing);
  });
}
