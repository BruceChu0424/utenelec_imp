import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_tree_branch_guide.dart';

void main() {
  Widget app({required bool dotted, VoidCallback? onTap}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 100,
        height: 36,
        child: Stack(
          children: [
            Positioned.fill(child: GestureDetector(onTap: onTap)),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 16,
              child: UtenTreeBranchGuide(
                depth: 0,
                ancestorContinuations: const [],
                isLastChild: true,
                hasExpandedChildren: true,
                indent: 12,
                toggleExtent: 32,
                maxVisualDepth: 10,
                color: Colors.grey,
                dotted: dotted,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Finder paint() => find.descendant(
    of: find.byType(UtenTreeBranchGuide),
    matching: find.byType(CustomPaint),
  );

  testWidgets(
    'directory dashes retain the parent-centre-to-bottom connection',
    (tester) async {
      await tester.pumpWidget(app(dotted: false));
      expect(
        tester.renderObject(paint()),
        paints..line(p1: const Offset(16, 18), p2: const Offset(16, 36)),
      );
      final solid = tester.widget<CustomPaint>(paint()).painter!;
      await tester.pumpWidget(app(dotted: true));
      expect(tester.getSize(paint()), const Size(16, 36));
      expect(
        tester.renderObject(paint()),
        paints
          ..line(p1: const Offset(16, 18), p2: const Offset(16, 19))
          ..line(p1: const Offset(16, 21), p2: const Offset(16, 22))
          ..line(p1: const Offset(16, 24), p2: const Offset(16, 25))
          ..line(p1: const Offset(16, 27), p2: const Offset(16, 28))
          ..line(p1: const Offset(16, 30), p2: const Offset(16, 31))
          ..line(p1: const Offset(16, 33), p2: const Offset(16, 34)),
      );
      expect(
        tester.widget<CustomPaint>(paint()).painter!.shouldRepaint(solid),
        true,
      );
    },
  );

  testWidgets('guide overlay leaves the host row pointer target available', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(app(dotted: true, onTap: () => taps++));
    await tester.tapAt(const Offset(10, 20));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
