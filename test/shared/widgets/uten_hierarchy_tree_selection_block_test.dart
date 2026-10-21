import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'selected circle keeps a long label and row controls separate dark=$dark scale=$scale',
        (tester) async {
          const name = '外贸客户分类完整名称及编号需要保留核对';
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                platform: TargetPlatform.windows,
              ),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(240, 300),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: SizedBox(
                    width: 240,
                    height: 300,
                    child: UtenCategoryTreeView<PaymentStyleNode>(
                      nodes: [
                        PaymentStyleNode(
                          id: 'root',
                          code: 'ROOT',
                          name: name,
                          children: const [],
                        ),
                      ],
                      flatLevelColors: true,
                      showSearch: false,
                      selectedIds: const {'root'},
                      trailingBuilder: (_) => const Icon(
                        Icons.lock_outline,
                        key: Key('row-protection'),
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final check = find.byIcon(Icons.check_circle_rounded);
          final label = find.text(name);
          expect(check, findsOneWidget);
          expect(
            tester.getRect(label).right,
            lessThanOrEqualTo(
              tester.getRect(find.byKey(const Key('row-protection'))).left,
            ),
          );
          expect(tester.getRect(check).right, lessThanOrEqualTo(240));
          expect(
            tester.getCenter(check).dy,
            closeTo(tester.getCenter(label).dy, 0.1),
          );
          expect(
            tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
            isTrue,
          );
          expect(find.byType(AnimatedPositioned), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'browse selection slides the circular check from the right without moving labels',
    (tester) async {
      await tester.pumpWidget(const _TreeHost());
      await tester.pumpAndSettle();
      final titleLeft = tester.getTopLeft(find.text('五金件'));
      await tester.tap(find.text('五金件'));
      await tester.pump();
      final marker = find.byKey(const ValueKey('hierarchy-selected-child'));
      final slide = find
          .ancestor(of: marker, matching: find.byType(SlideTransition))
          .first;
      expect(
        tester.widget<SlideTransition>(slide).position.value.dx,
        greaterThan(0),
      );
      await tester.pump(UtenAnim.fast ~/ 2);
      final middle = tester.widget<SlideTransition>(slide).position.value.dx;
      expect(middle, greaterThan(0));
      expect(middle, lessThan(0.6));
      await tester.pumpAndSettle();
      expect(tester.widget<SlideTransition>(slide).position.value, Offset.zero);
      expect(tester.getTopLeft(find.text('五金件')), titleLeft);
      await tester.tap(find.text('原材料'));
      await tester.pumpAndSettle();
      expect(marker, findsNothing);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(
        find.byKey(const ValueKey('hierarchy-selected-root')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion makes the selection immediate', (tester) async {
    await tester.pumpWidget(const _TreeHost(reducedMotion: true));
    await tester.tap(find.text('五金件'));
    await tester.pump();
    final marker = find.byKey(const ValueKey('hierarchy-selected-child'));
    final switcher = find
        .ancestor(of: marker, matching: find.byType(AnimatedSwitcher))
        .first;
    expect(tester.widget<AnimatedSwitcher>(switcher).duration, Duration.zero);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _TreeHost extends StatefulWidget {
  const _TreeHost({this.reducedMotion = false});
  final bool reducedMotion;
  @override
  State<_TreeHost> createState() => _TreeHostState();
}

class _TreeHostState extends State<_TreeHost> {
  String? selected;
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reducedMotion),
      child: Scaffold(
        body: SizedBox(
          width: 240,
          height: 500,
          child: UtenCategoryTreeView<PaymentStyleNode>(
            nodes: [
              PaymentStyleNode(
                id: 'root',
                code: 'ROOT',
                name: '原材料',
                children: [
                  PaymentStyleNode(
                    id: 'child',
                    code: 'CHILD',
                    name: '五金件',
                    children: const [],
                  ),
                ],
              ),
            ],
            showSearch: false,
            flatLevelColors: true,
            selectedIds: {?selected},
            onNodeTap: (node) => setState(() => selected = node.id),
          ),
        ),
      ),
    ),
  );
}
