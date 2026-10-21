import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

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
          final fill = find.byKey(
            const ValueKey('hierarchy-selection-fill-root'),
          );
          expect(fill, findsOneWidget);
          expect(tester.getRect(fill).left, 0);
          expect(
            tester.getRect(fill).right,
            greaterThanOrEqualTo(tester.getRect(label).right),
          );
          expect(
            tester.getRect(fill).right,
            lessThanOrEqualTo(
              tester.getRect(find.byKey(const Key('row-protection'))).left,
            ),
          );
          expect(
            tester.renderObject<RenderParagraph>(label).text.style?.color,
            UtenColors.treeLevelRow(0, dark: dark),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'browse selection slides the fill from the left and the check from the right together',
    (tester) async {
      await tester.pumpWidget(const _TreeHost());
      await tester.pumpAndSettle();
      final fill = find.byKey(const ValueKey('hierarchy-selection-fill-child'));
      expect(fill, findsOneWidget);
      expect(tester.getRect(fill).right, lessThanOrEqualTo(0));
      final fillWidth = tester.getSize(fill).width;
      double visibleFill() {
        final bounds = tester.getRect(fill);
        return bounds.right.clamp(0, 240) - bounds.left.clamp(0, 240);
      }

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
      expect(visibleFill(), 0);
      await tester.pump(UtenAnim.normal ~/ 2);
      expect(visibleFill(), greaterThan(0));
      expect(visibleFill(), lessThan(fillWidth));
      expect(tester.getSize(fill).width, fillWidth);
      final middle = tester.widget<SlideTransition>(slide).position.value.dx;
      expect(middle, greaterThan(0));
      expect(middle, lessThan(0.6));
      await tester.pumpAndSettle();
      expect(tester.widget<SlideTransition>(slide).position.value, Offset.zero);
      expect(tester.getRect(fill).left, 0);
      expect(visibleFill(), fillWidth);
      expect(tester.getTopLeft(find.text('五金件')), titleLeft);
      final childStyle = tester
          .renderObject<RenderParagraph>(find.text('五金件'))
          .text
          .style;
      expect(childStyle?.color, Colors.white);
      await tester.tap(find.text('原材料'));
      await tester.pump();
      await tester.pump(UtenAnim.normal ~/ 2);
      expect(visibleFill(), greaterThan(0));
      expect(visibleFill(), lessThan(fillWidth));
      expect(
        tester.widget<SlideTransition>(slide).position.value.dx,
        greaterThan(0),
      );
      await tester.pumpAndSettle();
      expect(visibleFill(), 0);
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
    final fill = find.byKey(const ValueKey('hierarchy-selection-fill-child'));
    expect(tester.getRect(fill).left, 0);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mode in UtenCategoryTreeMode.values) {
    testWidgets('flat $mode keeps the left fill and its selection control', (
      tester,
    ) async {
      await tester.pumpWidget(_TreeHost(mode: mode));
      await tester.pumpAndSettle();
      await tester.tap(find.text('五金件'));
      await tester.pumpAndSettle();
      final fill = find.byKey(const ValueKey('hierarchy-selection-fill-child'));
      expect(tester.getRect(fill).left, 0);
      expect(
        find.byIcon(Icons.check_circle_rounded),
        mode == UtenCategoryTreeMode.multi ? findsNothing : findsOneWidget,
      );
      if (mode == UtenCategoryTreeMode.multi) {
        expect(
          tester.widgetList<Checkbox>(find.byType(Checkbox)).last.value,
          isTrue,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'indented tree keeps its existing selection without a flat fill',
    (tester) async {
      await tester.pumpWidget(const _TreeHost(flat: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('五金件'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('hierarchy-selection-fill-child')),
        findsNothing,
      );
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _TreeHost extends StatefulWidget {
  const _TreeHost({
    this.reducedMotion = false,
    this.flat = true,
    this.mode = UtenCategoryTreeMode.none,
  });
  final bool reducedMotion;
  final bool flat;
  final UtenCategoryTreeMode mode;
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
            flatLevelColors: widget.flat,
            mode: widget.mode,
            selectedIds: {?selected},
            onNodeTap: (node) => setState(() => selected = node.id),
            onToggleSelect: (node) => setState(() => selected = node.id),
          ),
        ),
      ),
    ),
  );
}
