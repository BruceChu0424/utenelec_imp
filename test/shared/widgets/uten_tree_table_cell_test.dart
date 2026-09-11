import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

void main() {
  testWidgets('shows redundant hierarchy and a visible path', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: UtenTreeTableCell(
              depth: 2,
              sequence: 'P1.2.3',
              levelLabel: '组件 2 级',
              title: '安装螺钉包组件',
              subtitle: '80NG0012R · M4',
              pathLabel: '产品 A → 壳体 → 安装螺钉包组件',
              ancestorContinuations: [true, false],
              isLastChild: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('P1.2.3'), findsOneWidget);
    expect(find.text('组件 2 级'), findsOneWidget);
    expect(find.text('路径：产品 A → 壳体 → 安装螺钉包组件'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('安装螺钉包组件，级联号 P1\\.2\\.3，组件 2 级')),
      findsOneWidget,
    );
    expect(find.byType(IconButton), findsNothing);
    semantics.dispose();
  });

  testWidgets(
    'childCount badge is announced while collapsed and dropped once expanded',
    (tester) async {
      final semantics = tester.ensureSemantics();
      Widget cell(bool expanded) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: UtenTreeTableCell(
              depth: 1,
              sequence: 'P1.2',
              title: '壳体',
              hasChildren: true,
              childCount: 3,
              expanded: expanded,
              onToggle: () {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(cell(false));
      expect(find.byTooltip('展开 3 个下级'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('展开 壳体 的 3 个下级')), findsOneWidget);
      await tester.pumpWidget(cell(true));
      expect(find.byTooltip('收起下级'), findsOneWidget);
      expect(find.byTooltip('展开 3 个下级'), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('uses a dedicated 48dp toggle with expanded semantics', (
    tester,
  ) async {
    var toggles = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenTreeTableCell(
            depth: 1,
            sequence: '1.1',
            levelLabel: '组件 2 级',
            title: '有下级组件',
            hasChildren: true,
            toggleKey: const Key('tree-toggle'),
            onToggle: () => toggles++,
          ),
        ),
      ),
    );

    final toggle = find.byKey(const Key('tree-toggle'));
    expect(tester.getSize(toggle), const Size(48, 48));
    final semantic = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .where((widget) => widget.properties.label == '展开 有下级组件 的下级')
        .single;
    expect(semantic.properties.button, isTrue);
    expect(semantic.properties.expanded, isFalse);
    await tester.tap(toggle);
    expect(toggles, 1);
    semantics.dispose();
  });

  testWidgets('selected foreground stays white in light and dark themes', (
    tester,
  ) async {
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: ColoredBox(
              color: Color(0xFF006B4F),
              child: UtenTreeTableCell(
                depth: 1,
                sequence: '1.1',
                levelLabel: '组件 2 级',
                title: '选中组件',
                subtitle: '编号 A-1',
                pathLabel: '产品 → 选中组件',
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('选中组件')).style?.color, Colors.white);
      expect(
        tester.widget<Text>(find.text('组件 2 级')).style?.color,
        Colors.white,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('tree guide updates when terminal branch metadata changes', (
    tester,
  ) async {
    Widget cell(bool last) => MaterialApp(
      home: Scaffold(
        body: UtenTreeTableCell(
          depth: 3,
          sequence: '1.1.1',
          title: '深层组件',
          ancestorContinuations: const [true, false],
          isLastChild: last,
        ),
      ),
    );

    await tester.pumpWidget(cell(false));
    await tester.pumpWidget(cell(true));
    expect(tester.takeException(), isNull);
  });
}
