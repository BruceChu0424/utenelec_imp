import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

Widget _tree() => UtenCategoryTreeView<PaymentStyleNode>(
  nodes: [
    PaymentStyleNode(
      id: 'root',
      code: 'ROOT',
      name: '展开分类',
      children: [
        PaymentStyleNode(
          id: 'child',
          code: 'CHILD',
          name: '可见子分类',
          children: const [],
        ),
      ],
    ),
  ],
  showSearch: false,
  flatLevelColors: true,
);

FadeTransition _fade(WidgetTester tester) => tester.widget<FadeTransition>(
  find
      .ancestor(of: find.text('可见子分类'), matching: find.byType(FadeTransition))
      .first,
);

void main() {
  testWidgets(
    'visible children fade in and out without animating tree layout',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 300, height: 400, child: _tree()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开展开分类'));
      await tester.pump();
      expect(_fade(tester).opacity.value, 0);
      final firstTop = tester.getTopLeft(find.text('可见子分类')).dy;
      await tester.pump(UtenAnim.fast ~/ 2);
      expect(_fade(tester).opacity.value, greaterThan(0));
      expect(_fade(tester).opacity.value, lessThan(1));
      expect(tester.getTopLeft(find.text('可见子分类')).dy, lessThan(firstTop));
      await tester.pumpAndSettle();
      expect(_fade(tester).opacity.value, 1);
      await tester.tap(find.byTooltip('收起展开分类'));
      await tester.pump();
      expect(
        find.text('可见子分类'),
        findsOneWidget,
        reason: 'only the lazy visible rows remain during exit',
      );
      expect(find.text('可见子分类').hitTestable(), findsNothing);
      await tester.pump(UtenAnim.fast ~/ 2);
      expect(_fade(tester).opacity.value, greaterThan(0));
      expect(_fade(tester).opacity.value, lessThan(1));
      await tester.pumpAndSettle();
      expect(find.text('可见子分类'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reducing motion during exit removes children and stops branch tickers',
    (tester) async {
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: reduced,
            builder: (context, value, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: value),
              child: child!,
            ),
            child: Scaffold(
              body: SizedBox(width: 300, height: 400, child: _tree()),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('展开展开分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起展开分类'));
      await tester.pump();
      reduced.value = true;
      await tester.pumpAndSettle();
      expect(find.text('可见子分类'), findsNothing);
      await tester.tap(find.byTooltip('展开展开分类'));
      await tester.pump();
      expect(_fade(tester).opacity.value, 1);
      await tester.tap(find.byTooltip('收起展开分类'));
      await tester.pump();
      expect(find.text('可见子分类'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reversing a branch during exit keeps one row identity', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 300, height: 400, child: _tree())),
      ),
    );
    await tester.tap(find.byTooltip('展开展开分类'));
    await tester.pumpAndSettle();
    final child = tester.element(find.text('可见子分类'));
    await tester.tap(find.byTooltip('收起展开分类'));
    await tester.pump();
    await tester.pump(UtenAnim.fast ~/ 3);
    await tester.tap(find.byTooltip('展开展开分类'));
    await tester.pumpAndSettle();
    expect(tester.element(find.text('可见子分类')), same(child));
    expect(_fade(tester).opacity.value, 1);
    expect(tester.takeException(), isNull);
  });
}
