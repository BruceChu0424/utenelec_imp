import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_tree_branch_guide.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

void main() {
  for (final flat in [false, true]) {
    testWidgets('connected category branches keep sibling endings flat=$flat', (
      tester,
    ) async {
      await tester.pumpWidget(_app(flat: flat));
      await tester.pumpAndSettle();
      final rootX = tester.getTopLeft(find.text('成品')).dx;
      final branchX = tester.getTopLeft(find.text('外贸系列')).dx;
      expect(branchX - rootX, 12);
      expect(tester.getTopLeft(find.text('外贸白色')).dx - branchX, 12);
      expect(tester.getTopLeft(find.text('内销系列')).dx, branchX);

      UtenTreeBranchGuide guide(String id) => tester.widget(
        find.descendant(
          of: find.byKey(ValueKey('hierarchy-row:$id')),
          matching: find.byType(UtenTreeBranchGuide),
        ),
      );
      expect(guide('export').isLastChild, isFalse);
      expect(guide('export').hasExpandedChildren, isTrue);
      expect(guide('white').ancestorContinuations, [false, true]);
      expect(guide('white').isLastChild, isTrue);
      expect(guide('domestic').isLastChild, isTrue);
      expect(guide('domestic').hasExpandedChildren, isFalse);
      expect(guide('export').dotted, isTrue);
      final last = guide('domestic');
      final segments = utenTreeGuideSegments(
        depth: last.depth,
        ancestorContinuations: last.ancestorContinuations,
        isLastChild: last.isLastChild,
        height: flat ? 36 : 44,
        width: 12 + 16,
        connectorY: flat ? 18 : 22,
        indent: last.indent,
        toggleExtent: last.toggleExtent,
        maxVisualDepth: last.maxVisualDepth,
      );
      expect(segments.first.y2, flat ? 18 : 22);
      await tester.tap(find.byTooltip('收起外贸系列'));
      await tester.pumpAndSettle();
      expect(find.text('外贸白色'), findsNothing);
      expect(guide('export').hasExpandedChildren, isFalse);
      expect(find.byTooltip('展开外贸系列'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('filtered and transparent roots use the visible branch order', (
    tester,
  ) async {
    await tester.pumpWidget(_app(visible: const {'root', 'export', 'white'}));
    await tester.pumpAndSettle();
    expect(find.text('内销系列'), findsNothing);
    var branch = tester.widget<UtenTreeBranchGuide>(
      find.descendant(
        of: find.byKey(const ValueKey('hierarchy-row:export')),
        matching: find.byType(UtenTreeBranchGuide),
      ),
    );
    expect(branch.isLastChild, isTrue);
    await tester.pumpWidget(_app(hideRoot: true));
    await tester.pumpAndSettle();
    expect(find.text('成品'), findsNothing);
    branch = tester.widget<UtenTreeBranchGuide>(
      find.descendant(
        of: find.byKey(const ValueKey('hierarchy-row:export')),
        matching: find.byType(UtenTreeBranchGuide),
      ),
    );
    expect(branch.depth, 0);
    expect(branch.ancestorContinuations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow panels retain controls at large text in both themes', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(_app(width: 200, dark: dark, scale: 1.6));
      await tester.pumpAndSettle();
      expect(find.byTooltip('收起外贸系列'), findsOneWidget);
      expect(tester.getRect(find.text('外贸白色')).width, greaterThan(0));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('render shared category tree preview when requested', (
    tester,
  ) async {
    final output = Platform.environment['UTEN_TREE_PREVIEW_DIR'];
    if (output == null) return;
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    for (final dark in [false, true]) {
      final key = GlobalKey();
      await tester.pumpWidget(_app(dark: dark, captureKey: key, preview: true));
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final file = File('$output/category-tree-${dark ? 'dark' : 'light'}.png');
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }
  });
}

Widget _app({
  bool flat = true,
  bool dark = false,
  bool hideRoot = false,
  bool preview = false,
  double width = 300,
  double scale = 1,
  Set<String>? visible,
  Key? captureKey,
}) => MaterialApp(
  theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
    platform: TargetPlatform.windows,
  ),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(800, 600),
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(
      body: RepaintBoundary(
        key: captureKey,
        child: Material(
          child: SizedBox(
            width: width,
            height: preview ? 220 : 300,
            child: UtenCategoryTreeView<PaymentStyleNode>(
              nodes: preview ? _previewNodes : _nodes,
              showSearch: false,
              flatLevelColors: flat,
              initiallyExpandDepth: 3,
              initiallyCollapsedNames: const {'原材料'},
              selectedIds: const {'white'},
              visibleFilterIds: visible,
              passThrough: hideRoot ? (node) => node.id == 'root' : null,
            ),
          ),
        ),
      ),
    ),
  ),
);

final _nodes = [
  PaymentStyleNode(
    id: 'root',
    code: 'C',
    name: '成品',
    children: [
      PaymentStyleNode(
        id: 'export',
        code: 'C1',
        name: '外贸系列',
        children: [
          PaymentStyleNode(
            id: 'white',
            code: 'C11',
            name: '外贸白色',
            children: const [],
          ),
        ],
      ),
      PaymentStyleNode(
        id: 'domestic',
        code: 'C2',
        name: '内销系列',
        children: const [],
      ),
    ],
  ),
];

final _previewNodes = [
  ..._nodes,
  PaymentStyleNode(
    id: 'materials',
    code: 'M',
    name: '原材料',
    children: [
      PaymentStyleNode(
        id: 'metal',
        code: 'M1',
        name: '五金材料',
        children: const [],
      ),
    ],
  ),
];
