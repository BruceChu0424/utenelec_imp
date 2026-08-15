import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

void main() {
  testWidgets('搜索同时匹配类别名称和编号', (tester) async {
    await tester.pumpWidget(
      _treeApp([
        _node('root', 'EXP', '费用', [
          _node('office', 'A100', '办公费用'),
          _node('travel', 'B200', '差旅费用'),
        ]),
      ]),
    );

    await tester.enterText(find.byKey(const Key('category-tree-search')), '办公');
    await tester.pump();

    expect(find.text('办公费用（A100）'), findsOneWidget);
    expect(find.text('差旅费用（B200）'), findsNothing);
    expect(find.text('费用（EXP）'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('category-tree-search')),
      'b200',
    );
    await tester.pump();

    expect(find.text('差旅费用（B200）'), findsOneWidget);
    expect(find.text('办公费用（A100）'), findsNothing);
    expect(find.text('费用（EXP）'), findsOneWidget);
  });

  testWidgets('sortByCode=false 时保留服务端输入顺序', (tester) async {
    await tester.pumpWidget(
      _treeApp([
        _node('later-code', 'Z900', '优先显示'),
        _node('earlier-code', 'A100', '随后显示'),
      ], sortByCode: false),
    );

    final first = find.text('优先显示（Z900）');
    final second = find.text('随后显示（A100）');
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
  });

  testWidgets('外部统一搜索显示加载、错误和无结果反馈', (tester) async {
    final nodes = [_node('root', 'EXP', '费用')];

    await tester.pumpWidget(
      _treeApp(
        nodes,
        externalSearchQuery: '办公用品',
        externalSearchLoading: true,
        visibleFilterIds: const {},
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      _treeApp(
        nodes,
        externalSearchQuery: '办公用品',
        externalSearchError: '主档搜索失败',
        visibleFilterIds: const {},
      ),
    );
    expect(find.text('主档搜索失败'), findsOneWidget);

    await tester.pumpWidget(
      _treeApp(nodes, externalSearchQuery: '办公用品', visibleFilterIds: const {}),
    );
    expect(find.text('未找到匹配「办公用品」的分类或内容'), findsOneWidget);
  });
}

Widget _treeApp(
  List<PaymentStyleNode> nodes, {
  bool sortByCode = true,
  Set<String>? visibleFilterIds,
  String? externalSearchQuery,
  bool externalSearchLoading = false,
  String? externalSearchError,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 420,
      height: 560,
      child: UtenCategoryTreeView<PaymentStyleNode>(
        nodes: nodes,
        searchFieldKey: const Key('category-tree-search'),
        sortByCode: sortByCode,
        visibleFilterIds: visibleFilterIds,
        externalSearchQuery: externalSearchQuery,
        externalSearchLoading: externalSearchLoading,
        externalSearchError: externalSearchError,
      ),
    ),
  ),
);

PaymentStyleNode _node(
  String id,
  String code,
  String name, [
  List<PaymentStyleNode> children = const [],
]) => PaymentStyleNode(id: id, code: code, name: name, children: children);
