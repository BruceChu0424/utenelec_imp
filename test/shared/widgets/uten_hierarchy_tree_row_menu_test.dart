// 全站树行右键/长按菜单（2026-10-19 用户口径「所有树所有节点」）：
// 菜单由 UtenHierarchyTreeView 内置——宿主动作在前、「展开/收起」通用项在后，
// 右键即默认选中；无宿主动作的树也至少有展开/收起；全空不弹。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

List<PaymentStyleNode> _nodes() => [
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
];

Widget _app(Widget tree, {double width = 240}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: width, height: 560, child: tree),
  ),
);

UtenContextMenuRegion _regionOf(WidgetTester tester, Finder row) =>
    tester.widget<UtenContextMenuRegion>(
      find
          .ancestor(of: row, matching: find.byType(UtenContextMenuRegion))
          .first,
    );

void main() {
  testWidgets('无宿主动作的树：父行菜单仍有展开/收起，叶子为空不弹', (tester) async {
    var selected = <String>{};
    await tester.pumpWidget(
      _app(
        UtenCategoryTreeView<PaymentStyleNode>(
          nodes: _nodes(),
          mode: UtenCategoryTreeMode.single,
          selectedIds: selected,
          flatLevelColors: true,
          showSearch: false,
          onToggleSelect: (node) => selected = {...selected, node.id},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 父行（收起态）：条目只有通用「展开」。
    final parentRegion = _regionOf(tester, find.text('外贸钟'));
    final parentEntries = parentRegion.entriesBuilder();
    final parentItems = parentEntries.whereType<UtenMenuItem>().toList();
    expect(parentItems, hasLength(1));
    expect(parentItems.single.label, '展开');
    // 右键即默认选中：菜单弹开前置选中回调（single 下未选中才 toggle）。
    parentRegion.onMenuOpening!();
    await tester.pump();
    expect(selected, contains('branch'));

    // 通用项执行 = 展开子级。
    await parentItems.single.onTap();
    await tester.pumpAndSettle();
    expect(find.text('美国客户'), findsOneWidget);

    // 叶子行（无宿主动作、无子级）：空条目 → 不弹菜单。
    final leafRegion = _regionOf(tester, find.text('外贸刘'));
    expect(leafRegion.entriesBuilder(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宿主动作在前、展开/收起在后，中间竖线分组', (tester) async {
    var hostTapped = false;
    await tester.pumpWidget(
      _app(
        UtenCategoryTreeView<PaymentStyleNode>(
          nodes: _nodes(),
          flatLevelColors: true,
          showSearch: false,
          rowMenuBuilder: (node) => [
            UtenMenuItem(label: '宿主动作', onTap: () => hostTapped = true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final region = _regionOf(tester, find.text('外贸钟'));
    final entries = region.entriesBuilder();
    expect(entries, hasLength(3));
    expect(entries[0], isA<UtenMenuItem>());
    expect((entries[0] as UtenMenuItem).label, '宿主动作');
    expect(entries[1], isA<UtenMenuDivider>());
    expect((entries[2] as UtenMenuItem).label, '展开');

    await (entries[0] as UtenMenuItem).onTap();
    expect(hostTapped, isTrue);
    expect(tester.takeException(), isNull);
  });
}
