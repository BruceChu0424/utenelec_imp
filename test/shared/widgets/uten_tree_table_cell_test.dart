import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/widgets/uten_tree_table_cell.dart';

void main() {
  Finder guideOf(Key cellKey) => find.descendant(
    of: find.byKey(cellKey),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_TreeGuidePainter',
    ),
  );

  testWidgets('parent and child guides join at the arrow across padded rows', (
    tester,
  ) async {
    const parentKey = Key('parent-cell');
    const childKey = Key('child-cell');
    const toggleKey = Key('parent-toggle');
    for (final bleed in [4.0, 8.0]) {
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: bleed),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 88),
                          child: UtenTreeTableCell(
                            key: parentKey,
                            toggleKey: toggleKey,
                            depth: 0,
                            sequence: '1',
                            title: '父组件',
                            subtitle: '正在加载下级…',
                            hasChildren: true,
                            expanded: true,
                            guideBleed: bleed,
                            onToggle: () {},
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: bleed),
                        child: UtenTreeTableCell(
                          key: childKey,
                          depth: 1,
                          sequence: '',
                          sequenceInline: true,
                          title: '子组件',
                          ancestorContinuations: const [false],
                          isLastChild: true,
                          showLeafMarker: false,
                          guideBleed: bleed,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        final parentGuide = guideOf(parentKey);
        final childGuide = guideOf(childKey);
        final parentRect = tester.getRect(parentGuide);
        final childRect = tester.getRect(childGuide);
        final arrowCenter = tester.getCenter(find.byKey(toggleKey));
        expect(arrowCenter, parentRect.centerRight);
        expect(parentRect.bottom, childRect.top);
        expect(childRect.left + 24, arrowCenter.dx);
        expect(
          tester.renderObject(parentGuide),
          paints..line(
            p1: Offset(24, parentRect.height / 2),
            p2: Offset(24, parentRect.height),
          ),
        );
        expect(
          tester.renderObject(childGuide),
          paints
            ..line(
              p1: Offset.zero.translate(24, 0),
              p2: Offset(24, childRect.height / 2),
            )
            ..line(
              p1: Offset(24, childRect.height / 2),
              p2: Offset(40, childRect.height / 2),
            ),
        );
        expect(tester.getSize(find.byKey(toggleKey)), const Size(48, 48));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets(
    'collapsing a branch removes only its downward child connection',
    (tester) async {
      const cellKey = Key('branch-cell');
      Widget branch(bool expanded) => MaterialApp(
        home: Scaffold(
          body: UtenTreeTableCell(
            key: cellKey,
            depth: 1,
            sequence: '',
            sequenceInline: true,
            title: '父组件',
            ancestorContinuations: const [false],
            isLastChild: true,
            hasChildren: true,
            expanded: expanded,
            onToggle: () {},
          ),
        ),
      );
      await tester.pumpWidget(branch(true));
      final expandedPainter = tester
          .widget<CustomPaint>(guideOf(cellKey))
          .painter!;
      expect(
        tester.renderObject(guideOf(cellKey)),
        paints
          ..line(p1: const Offset(24, 0), p2: const Offset(24, 24))
          ..line(p1: const Offset(24, 24), p2: const Offset(40, 24))
          ..line(p1: const Offset(40, 24), p2: const Offset(40, 48)),
      );
      await tester.pumpWidget(branch(false));
      final collapsedPainter = tester
          .widget<CustomPaint>(guideOf(cellKey))
          .painter!;
      expect(collapsedPainter.shouldRepaint(expandedPainter), isTrue);
      expect(
        tester.renderObject(guideOf(cellKey)),
        paintsExactlyCountTimes(#drawLine, 2),
      );
    },
  );

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

  testWidgets(
    'titleBadge renders before the title and joins the semantics label',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              child: UtenTreeTableCell(
                depth: 0,
                sequence: '',
                sequenceInline: true,
                title: '测试产品0',
                titleBadge: Text('顶层', key: Key('top-level-badge')),
                titleBadgeLabel: '顶层',
              ),
            ),
          ),
        ),
      );
      expect(find.text('测试产品0'), findsOneWidget);
      // 徽章在名称同一排、位于名称之前（2026-10-07 物料分析汇总视图顶层行口径）。
      expect(
        tester.getTopLeft(find.byKey(const Key('top-level-badge'))).dx,
        lessThan(tester.getTopLeft(find.text('测试产品0')).dx),
      );
      // 徽章本体在 ExcludeSemantics 里，朗读名走 titleBadgeLabel。
      expect(find.bySemanticsLabel(RegExp('测试产品0，顶层')), findsOneWidget);
      semantics.dispose();
    },
  );

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

  // 2026-10-08 物料分析按产品视图：子件行左缘的分组竖线（块边界）——
  // depth>0 画在 x=8、贯穿整行；末位子件照画（不参与肘线收口）；
  // depth=0 的顶层行不画；默认关闭时一条都不多。
  testWidgets('subtreeRail draws a full-height block rail on child rows', (
    tester,
  ) async {
    const childKey = Key('rail-child');
    Widget cell({required bool rail, int depth = 1}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: UtenTreeTableCell(
            key: childKey,
            depth: depth,
            sequence: '',
            sequenceInline: true,
            title: '子组件',
            ancestorContinuations: const [false],
            isLastChild: true,
            showLeafMarker: false,
            subtreeRail: rail,
          ),
        ),
      ),
    );
    await tester.pumpWidget(cell(rail: false));
    expect(
      tester.renderObject(guideOf(childKey)),
      paints
        ..line(p1: const Offset(24, 0), p2: const Offset(24, 24))
        ..line(p1: const Offset(24, 24), p2: const Offset(40, 24)),
    );

    await tester.pumpWidget(cell(rail: true));
    final height = tester.getSize(guideOf(childKey)).height;
    expect(
      tester.renderObject(guideOf(childKey)),
      paints
        ..line(p1: const Offset(8, 0), p2: Offset(8, height))
        ..line(p1: const Offset(24, 0), p2: Offset(24, height / 2))
        ..line(p1: Offset(24, height / 2), p2: Offset(40, height / 2)),
    );

    // 顶层行（depth = 0）没有连线画布，分组线也无从谈起。
    await tester.pumpWidget(cell(rail: true, depth: 0));
    expect(guideOf(childKey), findsNothing);
  });

  // 2026-10-09 物料分析口径「没有子层级的行也加个展开 icon，灰色不能点击，
  // 统一好看」：无下级行的展开位画灰底粗箭头占位（圆底是一个 Container），
  // 占位宽度不变、不吃指针、不进语义；默认关闭时保持空位。
  testWidgets('mutedToggleWhenChildless renders a disabled glyph placeholder', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const titleKey = Key('muted-title');
    Widget cell(bool muted) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: UtenTreeTableCell(
            depth: 0,
            sequence: '',
            sequenceInline: true,
            title: '没有下级的行',
            showLeafMarker: false,
            mutedToggleWhenChildless: muted,
            titleBadge: const Text('顶层', key: titleKey),
          ),
        ),
      ),
    );

    await tester.pumpWidget(cell(false));
    expect(
      find.descendant(
        of: find.byType(UtenTreeTableCell),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
    final cellLeft = tester.getTopLeft(find.byType(UtenTreeTableCell)).dx;
    // 占位宽度不变：标题（徽章）仍在 48px 展开槽之后。
    expect(
      tester.getTopLeft(find.byKey(titleKey)).dx - cellLeft,
      greaterThanOrEqualTo(48),
    );

    await tester.pumpWidget(cell(true));
    expect(
      find.descendant(
        of: find.byType(UtenTreeTableCell),
        matching: find.byType(Container),
      ),
      findsOneWidget,
    );
    final cellLeft2 = tester.getTopLeft(find.byType(UtenTreeTableCell)).dx;
    expect(
      tester.getTopLeft(find.byKey(titleKey)).dx - cellLeft2,
      greaterThanOrEqualTo(48),
    );
    // 占位不是按钮：无按钮语义、无悬浮说明，点击整格也不产生任何语义动作。
    expect(
      tester
          .widgetList<Semantics>(find.byType(Semantics))
          .any((widget) => widget.properties.button ?? false),
      isFalse,
    );
    expect(find.byType(Tooltip), findsNothing);
    await tester.tap(find.byType(UtenTreeTableCell));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
