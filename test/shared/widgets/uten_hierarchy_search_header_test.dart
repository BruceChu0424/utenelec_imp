import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/models/uten_tree_node.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_search_header.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_tree_view.dart';

const _treeKey = Key('stable-category-tree');
const _searchKey = Key('category-search');
const _addKey = Key('add-root');
const _businessRoot = _Node(
  id: 'a103a748-f13e-42d9-b734-546188b01df8',
  name: '货品资料',
  children: [_Node(id: '183102fe-368c-432d-934c-744ee379e1da', name: '原材料')],
);
const _newRoot = _Node(
  id: '957547dd-e458-48f4-a8d1-de107e36b195',
  name: '另一业务根',
);

void main() {
  testWidgets('真实唯一根不按名称或根数量隐藏，新增同级根后层级与UUID选择稳定', (tester) async {
    String? tappedId;
    Widget tree(List<_Node> nodes, {Set<String> selected = const {}}) =>
        _categoryTree(
          nodes,
          selected: selected,
          onTap: (node) => tappedId = node.id,
        );

    await tester.pumpWidget(_app(tree([_businessRoot])));
    await tester.pumpAndSettle();
    expect(_label('货品资料'), findsOneWidget);
    expect(_label('原材料'), findsOneWidget);
    final rootX = tester.getTopLeft(_label('货品资料')).dx;
    final childX = tester.getTopLeft(_label('原材料')).dx;
    expect(childX - rootX, closeTo(16, 0.01));
    final originalState = tester.state(
      find.byType(UtenHierarchyTreeView<_Node>),
    );

    await tester.pumpWidget(_app(tree([_businessRoot, _newRoot])));
    await tester.pumpAndSettle();
    expect(
      tester.state(find.byType(UtenHierarchyTreeView<_Node>)),
      same(originalState),
    );
    expect(tester.getTopLeft(_label('货品资料')).dx, rootX);
    expect(tester.getTopLeft(_label('原材料')).dx, childX);
    expect(tester.getTopLeft(_label('另一业务根')).dx, rootX);

    await tester.tap(_label('另一业务根'));
    expect(tappedId, _newRoot.id, reason: '选择携带稳定UUID，不按行序号或名称反查');
    await tester.pumpWidget(
      _app(tree([_businessRoot, _newRoot], selected: {tappedId!})),
    );
    await tester.pumpAndSettle();
    expect(_rowSemantics(tester, '另一业务根').properties.selected, isTrue);
    expect(_rowSemantics(tester, '货品资料').properties.selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有显式displayWrapper透传，不成行不加深，增加真实根不改变旧层级', (tester) async {
    await tester.pumpWidget(_app(_categoryTree([_businessRoot])));
    await tester.pumpAndSettle();
    final rootX = tester.getTopLeft(_label('货品资料')).dx;
    final childX = tester.getTopLeft(_label('原材料')).dx;

    _Node wrapper(List<_Node> children) => _Node(
      id: 'display-only-wrapper',
      name: '任意展示容器名称',
      displayWrapper: true,
      children: children,
    );
    Widget wrappedTree(List<_Node> children) => _categoryTree([
      wrapper(children),
    ], passThrough: (node) => node.displayWrapper);

    await tester.pumpWidget(_app(wrappedTree([_businessRoot])));
    await tester.pumpAndSettle();
    expect(_label('任意展示容器名称'), findsNothing);
    expect(_label('货品资料'), findsOneWidget);
    expect(tester.getTopLeft(_label('货品资料')).dx, rootX);
    expect(tester.getTopLeft(_label('原材料')).dx, childX);

    await tester.pumpWidget(_app(wrappedTree([_businessRoot, _newRoot])));
    await tester.pumpAndSettle();
    expect(_label('任意展示容器名称'), findsNothing);
    expect(tester.getTopLeft(_label('货品资料')).dx, rootX);
    expect(tester.getTopLeft(_label('原材料')).dx, childX);
    expect(tester.getTopLeft(_label('另一业务根')).dx, rootX);
    expect(tester.takeException(), isNull);
  });

  for (final width in [220.0, 320.0]) {
    testWidgets('$width窄搜索栏在2倍字号下新增可触达，取消trailing不留空白', (tester) async {
      var adds = 0;
      Widget header({required bool withAction}) => UtenHierarchySearchHeader(
        search: const UtenSearchBar(key: _searchKey, hint: '搜索分类或货品名称'),
        trailing: withAction
            ? IconButton(
                key: _addKey,
                tooltip: '新增最外层分类',
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => adds++,
                icon: const Icon(Icons.add_rounded, size: 20),
              )
            : null,
      );

      await tester.pumpWidget(
        _app(header(withAction: true), width: width, textScale: 2),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '螺丝接线式');
      await tester.pumpAndSettle();
      final headerRect = tester.getRect(find.byType(UtenHierarchySearchHeader));
      final searchRect = tester.getRect(find.byKey(_searchKey));
      final addRect = tester.getRect(find.byKey(_addKey));
      expect(searchRect.width, greaterThan(80));
      expect(addRect.left - searchRect.right, closeTo(8, 0.01));
      expect(addRect.width, greaterThanOrEqualTo(36));
      expect(addRect.height, greaterThanOrEqualTo(36));
      expect(addRect.top, closeTo(searchRect.top, 0.01));
      expect(addRect.bottom, closeTo(searchRect.bottom, 0.01));
      expect(addRect.width, closeTo(searchRect.height, 0.01));
      expect(addRect.right, lessThanOrEqualTo(headerRect.right + 0.01));
      expect(find.byKey(_addKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('新增最外层分类'));
      expect(adds, 1);
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        _app(header(withAction: false), width: width, textScale: 2),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_addKey), findsNothing);
      final fullSearchRect = tester.getRect(find.byKey(_searchKey));
      expect(fullSearchRect.width, closeTo(width, 0.01));
      expect(
        fullSearchRect.right,
        tester.getRect(find.byType(UtenHierarchySearchHeader)).right,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('外部搜索controller替换同步输入与树，清空恢复节点且不代为dispose', (tester) async {
    final first = _TrackedController(text: '原材料');
    final second = _TrackedController(text: '另一业务根');
    var adds = 0;
    addTearDown(() {
      if (!first.disposed) first.dispose();
      if (!second.disposed) second.dispose();
    });
    Widget tree(TextEditingController? controller) => _categoryTree(
      [_businessRoot, _newRoot],
      searchController: controller,
      searchTrailing: IconButton(
        key: _addKey,
        tooltip: '新增最外层分类',
        onPressed: () => adds++,
        icon: const Icon(Icons.add_rounded),
      ),
      showSearch: true,
    );

    await tester.pumpWidget(_app(tree(first)));
    await tester.pumpAndSettle();
    final originalState = tester.state(
      find.byType(UtenHierarchyTreeView<_Node>),
    );
    expect(tester.widget<TextField>(find.byType(TextField)).controller, first);
    expect(find.byKey(_addKey).hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('新增最外层分类'));
    expect(adds, 1, reason: '分类薄封装应透传独立搜索尾部动作');
    expect(_label('原材料'), findsOneWidget);
    expect(_label('另一业务根'), findsNothing);

    await tester.pumpWidget(_app(tree(second)));
    await tester.pumpAndSettle();
    expect(
      tester.state(find.byType(UtenHierarchyTreeView<_Node>)),
      same(originalState),
    );
    expect(tester.widget<TextField>(find.byType(TextField)).controller, second);
    expect(_label('另一业务根'), findsOneWidget);
    expect(_label('原材料'), findsNothing);
    expect(first.disposed, isFalse);
    first.text = '旧controller不再参与过滤';
    await tester.pump();
    expect(_label('另一业务根'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '原材料');
    await tester.pumpAndSettle();
    expect(second.text, '原材料');
    expect(first.text, '旧controller不再参与过滤');
    expect(_label('原材料'), findsOneWidget);
    expect(_label('另一业务根'), findsNothing);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(second.text, '');
    expect(_label('货品资料'), findsOneWidget);
    expect(_label('原材料'), findsOneWidget);
    expect(_label('另一业务根'), findsOneWidget);

    await tester.pumpWidget(_app(tree(null)));
    await tester.pumpAndSettle();
    expect(second.disposed, isFalse);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller,
      isNot(same(second)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(first.disposed, isFalse);
    expect(second.disposed, isFalse);
    first.text = '父组件仍可复用';
    second.text = '卸载后仍可复用';
    expect(tester.takeException(), isNull);
  });
}

Widget _categoryTree(
  List<_Node> nodes, {
  Set<String> selected = const {},
  ValueChanged<_Node>? onTap,
  bool Function(_Node)? passThrough,
  TextEditingController? searchController,
  Widget? searchTrailing,
  bool showSearch = false,
}) => UtenCategoryTreeView<_Node>(
  key: _treeKey,
  nodes: nodes,
  selectedIds: selected,
  onNodeTap: onTap,
  initiallyExpandDepth: 3,
  sortByCode: false,
  passThrough: passThrough,
  showSearch: showSearch,
  searchFieldKey: _searchKey,
  searchController: searchController,
  searchTrailing: searchTrailing,
);

Widget _app(Widget child, {double width = 320, double textScale = 1}) =>
    MaterialApp(
      theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 500,
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      ),
    );

Finder _label(String label) =>
    find.byWidgetPredicate((widget) => widget is Text && widget.data == label);

Semantics _rowSemantics(WidgetTester tester, String label) =>
    tester.widget<Semantics>(
      find.ancestor(
        of: _label(label),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.selected != null,
        ),
      ),
    );

class _Node implements UtenTreeNode<_Node> {
  const _Node({
    required this.id,
    required this.name,
    this.children = const [],
    this.displayWrapper = false,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  String get code => id;
  @override
  final List<_Node> children;
  final bool displayWrapper;
  @override
  bool get hasChildren => children.isNotEmpty;
}

class _TrackedController extends TextEditingController {
  _TrackedController({super.text});

  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
