import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

void main() {
  testWidgets('shows redundant hierarchy cues', (tester) async {
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
              ancestorContinuations: [true, false],
              isLastChild: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('P1.2.3'), findsOneWidget);
    expect(find.text('组件 2 级'), findsOneWidget);
    // 2026-09-12 用户口径：不再有「路径：A → B」堆叠行（pathLabel 已退役）。
    expect(find.textContaining('路径：'), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp('安装螺钉包组件，级联号 P1\\.2\\.3，组件 2 级')),
      findsOneWidget,
    );
    expect(find.byType(IconButton), findsNothing);
    semantics.dispose();
  });

  // 2026-09-14 物料分析系表格口径（ADR-081 §4）：级联号传空串即不渲染徽标、
  // showLeafMarker:false 关掉叶子圆点；两者都只作用于显式传参的宿主。
  testWidgets('empty sequence drops the badge and keeps the title first', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: UtenTreeTableCell(
              depth: 2,
              sequence: '',
              sequenceInline: true,
              title: '安装螺钉包组件',
            ),
          ),
        ),
      ),
    );
    expect(find.text('安装螺钉包组件'), findsOneWidget);
    expect(find.textContaining('P1'), findsNothing);
  });

  testWidgets('showLeafMarker:false drops the leaf dot but keeps alignment', (
    tester,
  ) async {
    Widget cell(bool marker) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: UtenTreeTableCell(
            depth: 2,
            sequence: '',
            title: '螺钉',
            showLeafMarker: marker,
          ),
        ),
      ),
    );
    await tester.pumpWidget(cell(true));
    final withDot = tester.getSize(find.byType(UtenTreeTableCell));
    expect(
      find.descendant(
        of: find.byType(UtenTreeTableCell),
        matching: find.byType(Container),
      ),
      findsWidgets,
    );
    await tester.pumpWidget(cell(false));
    // 占位宽度不变（名称列在各层级仍对齐），只是不画那枚圆点。
    expect(tester.getSize(find.byType(UtenTreeTableCell)), withDot);
    expect(
      find.descendant(
        of: find.byType(UtenTreeTableCell),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
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
    // 2026-09-12 用户口径「箭头粗一点、浅色模式亮一点」：细线图标换自绘 3px 圆头
    // 粗箭头（锁住字形不再退回 Icons 线性款）。
    final glyphPainters = tester
        .widgetList<CustomPaint>(
          find.descendant(of: toggle, matching: find.byType(CustomPaint)),
        )
        .map((widget) => widget.painter)
        .where(
          (painter) => painter.runtimeType.toString().contains('ThickChevron'),
        )
        .toList();
    expect(glyphPainters, hasLength(1));
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
