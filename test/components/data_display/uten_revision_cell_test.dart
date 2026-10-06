// UtenRevisionCell：单元格内旧新对照(旧值红删除线 / 新值绿底加粗 / 差异位红粗下划线)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_cell.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';

const _before = '110105194912310018';
const _after = '11010519491231002X';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: Center(child: child)),
    );

/// 新值行(Container 内)的 Text.rich 逐字符 span 列表。
/// Text.rich 会把传入的 span 再包一层外层 TextSpan(挂默认样式)，先剥掉。
List<TextSpan> _afterSpans(WidgetTester tester) {
  final rich = tester.widget<RichText>(
    find
        .descendant(of: find.byType(Container), matching: find.byType(RichText))
        .first,
  );
  final cellSpan = (rich.text as TextSpan).children!.single as TextSpan;
  return cellSpan.children!.whereType<TextSpan>().toList();
}

/// 按 Semantics.label 精确找(不用 bySemanticsLabel：label 会与子文本合并)。
Finder _semanticsWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.label == label,
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('旧值删除线红字、新值绿底绿字($brightness)', (tester) async {
      await tester.pumpWidget(
        _host(
          const UtenRevisionCell(before: _before, after: _after),
          brightness: brightness,
        ),
      );
      final removed = brightness == Brightness.dark
          ? UtenColors.errorOnDark
          : UtenColors.errorText;
      final added = brightness == Brightness.dark
          ? UtenColors.successOnDark
          : UtenColors.successText;

      final beforeText = tester.widget<Text>(find.text(_before));
      expect(beforeText.style!.color, removed);
      expect(beforeText.style!.decoration, TextDecoration.lineThrough);
      expect(beforeText.style!.decorationColor, removed, reason: '删除线同色');

      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration! as BoxDecoration;
      expect(
        decoration.color,
        brightness == Brightness.dark
            ? added.withValues(alpha: 0.12)
            : UtenColors.successBg,
        reason: '新值行底色走 token 函数，暗色自动换透明度方案',
      );
      expect(decoration.borderRadius, BorderRadius.circular(4));

      final spans = _afterSpans(tester);
      expect(spans, isNotEmpty);
      for (final span in spans) {
        expect(span.style!.color, added);
        expect(span.style!.fontWeight, FontWeight.w700);
        expect(span.style!.decoration, isNull, reason: '未变化的字符不加下划线');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('差异位高亮：只标 changedPositions 指定的字符', (tester) async {
    await tester.pumpWidget(
      _host(
        const UtenRevisionCell(
          before: _before,
          after: _after,
          changedPositions: [17, 18],
        ),
      ),
    );
    final spans = _afterSpans(tester);
    expect(spans.map((s) => s.text).join(), _after, reason: 'span 按位拼回新值');
    final highlighted = spans
        .where((s) => s.style!.color == UtenColors.errorText)
        .toList();
    expect(highlighted, hasLength(2), reason: '只有第 17/18 位标红');
    expect(highlighted.map((s) => s.text).join(), '2X');
    expect(
      highlighted.every((s) => s.style!.fontWeight == FontWeight.w800),
      isTrue,
    );
    expect(
      highlighted.every((s) => s.style!.decoration == TextDecoration.underline),
      isTrue,
    );
    expect(
      spans
          .where((s) => s.style!.color == UtenColors.successText)
          .every((s) => s.style!.fontWeight == FontWeight.w700),
      isTrue,
    );
  });

  testWidgets('masked：脱敏值不做差异位高亮', (tester) async {
    await tester.pumpWidget(
      _host(
        const UtenRevisionCell(
          before: '1101**********0018',
          after: '1101**********002X',
          changedPositions: [17],
          masked: true,
        ),
      ),
    );
    final spans = _afterSpans(tester);
    expect(spans, isNotEmpty);
    for (final span in spans) {
      expect(span.style!.color, UtenColors.successText);
      expect(span.style!.decoration, isNull);
    }
  });

  testWidgets('旧值为空：灰字占位不加删除线，可自定义占位文字', (tester) async {
    await tester.pumpWidget(
      _host(const UtenRevisionCell(before: null, after: '新值')),
    );
    final empty = tester.widget<Text>(find.text('(空)'));
    expect(empty.style!.color, ThemeData().colorScheme.onSurfaceVariant);
    expect(empty.style!.decoration, isNull, reason: '原本为空没有可划掉的旧值');

    await tester.pumpWidget(
      _host(const UtenRevisionCell(before: '', after: '新值', emptyText: '未登记')),
    );
    expect(find.text('未登记'), findsOneWidget);
    expect(find.text('(空)'), findsNothing);
  });

  testWidgets('after 为 null：只渲染旧值行，不出新值容器', (tester) async {
    await tester.pumpWidget(
      _host(const UtenRevisionCell(before: _before, after: null)),
    );
    expect(find.text(_before), findsOneWidget);
    expect(find.byType(Container), findsNothing);
    expect(_semanticsWithLabel('修改前 $_before'), findsOneWidget);
  });

  testWidgets('afterTrailing 渲染在新值行尾部', (tester) async {
    await tester.pumpWidget(
      _host(
        UtenRevisionCell(
          before: _before,
          after: _after,
          afterTrailing: IconButton(
            key: const Key('cell-adopt'),
            onPressed: () {},
            icon: const Icon(Icons.check_rounded),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('cell-adopt')), findsOneWidget);
    final trailingRect = tester.getRect(find.byKey(const Key('cell-adopt')));
    final richRect = tester.getRect(
      find
          .descendant(
            of: find.byType(Container),
            matching: find.byType(RichText),
          )
          .first,
    );
    expect(
      trailingRect.left,
      greaterThan(richRect.right),
      reason: '尾部部件排在新值文字之后',
    );
  });

  testWidgets('Semantics 读出「修改前 X，改为 Y」', (tester) async {
    await tester.pumpWidget(
      _host(const UtenRevisionCell(before: _before, after: _after)),
    );
    expect(_semanticsWithLabel('修改前 $_before，改为 $_after'), findsOneWidget);
  });
}
