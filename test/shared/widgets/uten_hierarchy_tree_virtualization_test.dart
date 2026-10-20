import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_tree_view.dart';

void main() {
  for (final height in [400.0, 900.0]) {
    testWidgets(
      'expanded 3000-node branch mounts viewport rows at height $height',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(800, height));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var built = 0;
        final children = [
          for (var i = 0; i < 3000; i++)
            PaymentStyleNode(
              id: 'child-$i',
              code: '$i',
              name: '物料分类$i',
              children: const [],
            ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: UtenHierarchyTreeView<PaymentStyleNode>(
                  nodes: [
                    PaymentStyleNode(
                      id: 'root',
                      code: 'ROOT',
                      name: '全部分类',
                      children: children,
                    ),
                  ],
                  searchHint: '搜索',
                  emptyNoun: '分类',
                  showSearch: false,
                  flatLevelColors: true,
                  trailingBuilder: (_) {
                    built++;
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          built,
          lessThan(80),
          reason: 'opening a branch must not build all its descendants',
        );
        expect(find.text('物料分类2999'), findsNothing);
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        scroll.position.jumpTo(600);
        await tester.pumpAndSettle();
        expect(
          built,
          lessThan(120),
          reason: 'normal scrolling only builds the next viewport',
        );
        for (var attempt = 0; attempt < 5; attempt++) {
          scroll.position.jumpTo(scroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
        }
        expect(find.text('物料分类2999'), findsOneWidget);
        expect(
          find.byType(InkWell).evaluate().length,
          lessThan(80),
          reason: 'a distant scrollbar jump still retains only viewport rows',
        );
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('收起全部分类'));
        await tester.pumpAndSettle();
        expect(find.text('物料分类0'), findsNothing);
        await tester.tap(find.byTooltip('展开全部分类'));
        await tester.pumpAndSettle();
        expect(find.text('物料分类0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
