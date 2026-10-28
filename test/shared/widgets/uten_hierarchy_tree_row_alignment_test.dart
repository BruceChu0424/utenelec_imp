import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';

void main() {
  testWidgets(
    'flat category rows use 36 desktop pixels and retain 48 touch targets',
    (tester) async {
      for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
        await tester.pumpWidget(
          _app(_categories(), width: 240, platform: platform),
        );
        await tester.pumpAndSettle();
        final title = find.text('外贸钟');
        final row = find
            .ancestor(of: title, matching: find.byType(InkWell))
            .first;
        expect(
          tester.getSize(row).height,
          platform == TargetPlatform.windows ? 36 : 48,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('分类同层父节点和叶节点的名称起点一致', (tester) async {
    await tester.pumpWidget(_app(_categories(), width: 240));

    expect(
      tester.getTopLeft(find.text('外贸钟')).dx,
      tester.getTopLeft(find.text('外贸刘')).dx,
    );
  });

  testWidgets('小号方框加减按钮与分类名称垂直居中', (tester) async {
    await tester.pumpWidget(_app(_categories(), width: 240));

    expect(
      tester.getCenter(find.byIcon(Icons.add)).dy,
      tester.getCenter(find.text('外贸钟')).dy,
    );
    expect(tester.getSize(find.byIcon(Icons.add)), const Size(12, 12));
  });

  testWidgets('窄分类栏的选中标记始终与名称同行', (tester) async {
    await tester.pumpWidget(
      _app(_categories(selected: const {'branch'}), width: 240),
    );

    expect(
      tester.getCenter(find.byIcon(Icons.check_circle_rounded)).dy,
      tester.getCenter(find.text('外贸钟')).dy,
    );
  });

  testWidgets('部门徽标人数和多选框在窄栏仍与名称同行', (tester) async {
    await tester.pumpWidget(
      _app(
        UtenDepartmentTreeView(
          nodes: [
            DepartmentNode(
              id: 'production',
              code: 'DEPT_PROD',
              name: '生产部',
              level: '一级部门',
              children: const [],
            ),
          ],
          mode: UtenDepartmentTreeMode.multi,
          selectedIds: const {'production'},
          showSearch: false,
          trailingBuilder: (_) => const Text('12人'),
          onToggleSelect: (_) {},
        ),
        width: 220,
      ),
    );

    final label = tester.getRect(find.text('生产部'));
    expect(tester.getCenter(find.text('部')).dy, label.center.dy);
    expect(tester.getCenter(find.text('12人')).dy, label.center.dy);
    expect(tester.getCenter(find.byType(Checkbox)).dy, label.center.dy);
    expect(tester.getRect(find.text('部')).right, lessThan(label.left));
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开后只显示原分类标题且完整祖先路径仍可读取', (tester) async {
    await tester.pumpWidget(_app(_categories(), width: 240));
    await tester.tap(find.byTooltip('展开外贸钟'));
    await tester.pump();

    expect(find.text('美国客户'), findsOneWidget);
    expect(find.textContaining('第2层'), findsNothing);
    expect(find.byTooltip('外贸钟 / 美国客户'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('美国客户')).dx,
      tester.getTopLeft(find.text('外贸刘')).dx + 12,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('长名称在各字体比例保持一行且选中和展开语义不变', (tester) async {
    final semantics = tester.ensureSemantics();
    const name = '完整名称与编号需要保留供辅助阅读的长客户分类';
    const label = name;
    try {
      for (final scale in [0.8, 1.0, 1.6]) {
        await tester.pumpWidget(
          _app(
            UtenCategoryTreeView<PaymentStyleNode>(
              nodes: [
                PaymentStyleNode(
                  id: 'long',
                  code: 'LONG001',
                  name: name,
                  children: [
                    PaymentStyleNode(
                      id: 'child-long',
                      code: 'LONG002',
                      name: '子级',
                      children: const [],
                    ),
                  ],
                ),
              ],
              mode: UtenCategoryTreeMode.single,
              selectedIds: const {'long'},
              showSearch: false,
              flatLevelColors: true,
            ),
            width: 360,
            scale: scale,
          ),
        );

        final title = find.text(label);
        expect(tester.getSize(title).height, lessThan(40));
        expect(find.byTooltip(label), findsOneWidget);
        expect(
          tester.getSemantics(title).getSemanticsData().label,
          contains(label),
        );
        expect(
          tester.getCenter(find.byIcon(Icons.check_circle_rounded)).dy,
          tester.getCenter(title).dy,
        );
        final selectedRow = find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.selected == true &&
              widget.properties.expanded == false,
        );
        expect(selectedRow, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('触屏展开目标保持48且叶节点占位相同，选择不会误展开', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _app(
        _categories(onSelect: (node) => selected.add(node.id)),
        width: 320,
        platform: TargetPlatform.android,
      ),
    );

    final expand = find.byTooltip('展开外贸钟');
    final button = find.byType(IconButton);
    expect(expand, findsOneWidget);
    expect(tester.getSize(button), const Size(48, 48));
    expect(
      tester.getTopLeft(find.text('外贸钟')).dx,
      tester.getTopLeft(find.text('外贸刘')).dx,
    );
    await tester.tap(find.text('外贸钟'));
    await tester.pump();
    expect(selected, ['branch']);
    expect(find.text('美国客户'), findsNothing);

    await tester.tap(button);
    await tester.pump();
    expect(selected, ['branch']);
    expect(find.text('美国客户'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不可选骨架仍可展开且不会误触发选择', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _app(
        _categories(
          onSelect: (node) => selected.add(node.id),
          enabled: (node) => node.id == 'child',
        ),
        width: 240,
      ),
    );

    await tester.tap(find.text('外贸钟'));
    await tester.pump();
    expect(find.text('美国客户'), findsOneWidget);
    expect(selected, isEmpty);
    await tester.tap(find.text('外贸刘'));
    await tester.pump();
    expect(selected, isEmpty);
    await tester.tap(find.text('美国客户'));
    await tester.pump();
    expect(selected, ['child']);
    expect(tester.takeException(), isNull);
  });
}

Widget _categories({
  Set<String> selected = const {},
  ValueChanged<PaymentStyleNode>? onSelect,
  bool Function(PaymentStyleNode)? enabled,
}) => UtenCategoryTreeView<PaymentStyleNode>(
  nodes: [
    PaymentStyleNode(
      id: 'branch',
      code: 'KF000001',
      name: '外贸钟',
      children: [
        PaymentStyleNode(
          id: 'child',
          code: 'KF000002',
          name: '美国客户',
          children: const [],
        ),
      ],
    ),
    PaymentStyleNode(
      id: 'leaf',
      code: 'KF000003',
      name: '外贸刘',
      children: const [],
    ),
  ],
  mode: UtenCategoryTreeMode.single,
  selectedIds: selected,
  flatLevelColors: true,
  showSearch: false,
  onToggleSelect: onSelect ?? (_) {},
  nodeEnabledPredicate: enabled,
);

Widget _app(
  Widget tree, {
  required double width,
  double scale = 1,
  TargetPlatform platform = TargetPlatform.windows,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(800, 600),
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(
      body: SizedBox(width: width, height: 560, child: tree),
    ),
  ),
);
