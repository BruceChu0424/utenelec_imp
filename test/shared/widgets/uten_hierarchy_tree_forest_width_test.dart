import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_hierarchy_content_width.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_tree_view.dart';
import 'package:uten_imp/shared/models/uten_tree_node.dart';

const _longName = '屏外最长分类标题必须完整显示并且不能在滚到末尾时才改变分栏宽度';
const _longLabel = '$_longName(C099)';

void main() {
  testWidgets('分类薄封装重建复用2440节点的标题量测，不扫描折叠后代', (tester) async {
    final controller = UtenHierarchyContentWidthController();
    addTearDown(controller.dispose);
    var namesRead = 0;
    final nodes = [
      for (var root = 0; root < 40; root++)
        _CountedCategory('root-$root', '分类$root', () => namesRead++, [
          for (var child = 0; child < 60; child++)
            _CountedCategory(
              'child-$root-$child',
              '屏外分类$root-$child',
              () => namesRead++,
            ),
        ]),
    ];
    Widget frame(Set<String> selected) => MaterialApp(
      home: Scaffold(
        body: UtenHierarchyContentWidthScope(
          controller: controller,
          child: UtenCategoryTreeView<_CountedCategory>(
            nodes: nodes,
            showSearch: false,
            selectedIds: selected,
          ),
        ),
      ),
    );
    await tester.pumpWidget(frame(const {}));
    await tester.pumpAndSettle();
    expect(namesRead, greaterThanOrEqualTo(2440));
    namesRead = 0;
    await tester.pumpWidget(frame(const {'root-1'}));
    await tester.pumpAndSettle();
    expect(namesRead, lessThan(120), reason: '只更新已显示的40个根，不重测2400个折叠后代');
    expect(tester.takeException(), isNull);
  });

  testWidgets('屏外最长分类决定初始自然宽，主动缩窄后滚动往返不反弹', (tester) async {
    tester.view.physicalSize = const Size(2000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SizedBox(
            height: 160,
            child: UtenSplitView(
              initialLeadingWidth: 220,
              minLeadingWidth: 200,
              maxLeadingWidth: 1600,
              minTrailingWidth: 320,
              leading: ColoredBox(
                key: const Key('forest-pane'),
                color: Colors.white,
                child: UtenCategoryTreeView<PaymentStyleNode>(
                  nodes: _forest(),
                  mode: UtenCategoryTreeMode.single,
                  selectedIds: const {'row-99'},
                  flatLevelColors: true,
                  showSearch: false,
                ),
              ),
              trailing: const Text('详情'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_longName), findsNothing, reason: '最长标题仍在视口和缓存外');
    final naturalWidth = tester
        .getSize(find.byKey(const Key('forest-pane')))
        .width;
    expect(naturalWidth, greaterThan(400));
    await tester.drag(find.byTooltip('拖动调整宽度 · 双击复位'), const Offset(-1800, 0));
    await tester.pumpAndSettle();
    final compactWidth = tester
        .getSize(find.byKey(const Key('forest-pane')))
        .width;
    expect(compactWidth, 200);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text(_longName), findsOneWidget);
    expect(
      tester
          .renderObject<RenderParagraph>(find.text(_longName))
          .didExceedMaxLines,
      isTrue,
    );
    expect(find.byTooltip(_longName), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('forest-pane'))).width,
      compactWidth,
    );
    scroll.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text(_longName), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('forest-pane'))).width,
      compactWidth,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('选择复用屏外标题缓存而系统字体变化会重新测量', (tester) async {
    final controller = UtenHierarchyContentWidthController();
    addTearDown(controller.dispose);
    final nodes = _forest();
    var measurements = 0;
    String label(PaymentStyleNode node) {
      if (node.id == 'row-99') measurements++;
      return '${node.name}(${node.code})';
    }

    await tester.pumpWidget(_scope(controller, nodes, label: label));
    await tester.pumpAndSettle();
    expect(find.text(_longLabel), findsNothing);
    expect(measurements, 1);
    final original = controller.minimumWidth;
    await tester.pumpWidget(
      _scope(controller, nodes, label: label, selected: const {'row-0'}),
    );
    await tester.pumpAndSettle();
    expect(measurements, 1, reason: '选择变化不会重走100个模型标题');
    expect(controller.minimumWidth, original);
    await tester.binding.handleSystemMessage({'type': 'fontsChange'});
    await tester.pumpAndSettle();
    expect(measurements, 2);
    expect(controller.minimumWidth, original);
    expect(tester.takeException(), isNull);
  });

  testWidgets('字体缩放和数据替换可缩回正确下限，切scope和dispose无旧报告', (tester) async {
    final first = UtenHierarchyContentWidthController();
    final second = UtenHierarchyContentWidthController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final nodes = _forest();
    await tester.pumpWidget(_scope(first, nodes));
    await tester.pumpAndSettle();
    final original = first.minimumWidth;
    expect(original, greaterThan(400));
    await tester.pumpWidget(_scope(first, nodes, scale: 1.6));
    await tester.pumpAndSettle();
    expect(first.minimumWidth, greaterThan(original));
    await tester.pumpWidget(_scope(first, nodes));
    await tester.pumpAndSettle();
    expect(first.minimumWidth, original);
    await tester.pumpWidget(_scope(second, nodes));
    await tester.pumpAndSettle();
    expect(first.minimumWidth, 0);
    expect(second.minimumWidth, original);
    await tester.pumpWidget(_scope(second, [_node('short', 'S', '短分类')]));
    await tester.pumpAndSettle();
    expect(second.minimumWidth, lessThan(original));
    await tester.pumpWidget(_scope(second, const []));
    await tester.pumpAndSettle();
    expect(second.minimumWidth, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(second.minimumWidth, 0);
    await tester.binding.handleSystemMessage({'type': 'fontsChange'});
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('透传节点不测自身，折叠后的模型标题仍提前保护', (tester) async {
    final controller = UtenHierarchyContentWidthController();
    addTearDown(controller.dispose);
    final nodes = [
      _node('hidden-company', 'ROOT', '隐藏公司标题' * 20, [
        _node('branch', 'B', '父分类', [_node('row-99', 'C099', _longName)]),
      ]),
    ];
    final measured = <String>{};
    String label(PaymentStyleNode node) {
      measured.add(node.id);
      return '${node.name}(${node.code})';
    }

    await tester.pumpWidget(
      _scope(
        controller,
        nodes,
        label: label,
        passThrough: (node) => node.id == 'hidden-company',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_longLabel), findsNothing, reason: '长标题还在折叠的父节点中');
    expect(measured, contains('row-99'));
    expect(measured, isNot(contains('hidden-company')));
    expect(controller.minimumWidth, greaterThan(400));
    expect(tester.takeException(), isNull);
  });
}

List<PaymentStyleNode> _forest() => [
  for (var index = 0; index < 100; index++)
    _node(
      'row-$index',
      'C${index.toString().padLeft(3, '0')}',
      index == 99 ? _longName : '分类$index',
    ),
];

PaymentStyleNode _node(
  String id,
  String code,
  String name, [
  List<PaymentStyleNode> children = const [],
]) => PaymentStyleNode(id: id, code: code, name: name, children: children);

Widget _scope(
  UtenHierarchyContentWidthController controller,
  List<PaymentStyleNode> nodes, {
  String Function(PaymentStyleNode)? label,
  Set<String> selected = const {},
  double scale = 1,
  bool Function(PaymentStyleNode)? passThrough,
}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.windows),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(800, 600),
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(
      body: SizedBox(
        width: 240,
        height: 160,
        child: UtenHierarchyContentWidthScope(
          controller: controller,
          child: UtenHierarchyTreeView<PaymentStyleNode>(
            key: const Key('cached-forest'),
            nodes: nodes,
            searchHint: '搜索分类',
            emptyNoun: '分类',
            mode: UtenTreeSelectMode.single,
            selectedIds: selected,
            showSearch: false,
            flatLevelColors: true,
            labelOf: label ?? _label,
            passThrough: passThrough,
          ),
        ),
      ),
    ),
  ),
);

String _label(PaymentStyleNode node) => '${node.name}(${node.code})';

class _CountedCategory extends UtenTreeNode<_CountedCategory> {
  _CountedCategory(
    this.id,
    this._name,
    this.onNameRead, [
    this.children = const [],
  ]);
  @override
  final String id;
  final String _name;
  final VoidCallback onNameRead;
  @override
  String get name {
    onNameRead();
    return _name;
  }

  @override
  String get code => id;
  @override
  final List<_CountedCategory> children;
  @override
  bool get hasChildren => children.isNotEmpty;
}
