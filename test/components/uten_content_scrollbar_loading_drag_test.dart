import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';

void main() {
  for (final reverse in [false, true]) {
    testWidgets('held thumb stays continuous as rows load reverse=$reverse', (
      tester,
    ) async {
      final controller = ScrollController();
      final count = ValueNotifier(60);
      addTearDown(controller.dispose);
      addTearDown(count.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: ValueListenableBuilder<int>(
                valueListenable: count,
                builder: (_, value, _) => Stack(
                  children: [
                    ListView.builder(
                      controller: controller,
                      reverse: reverse,
                      itemExtent: 48,
                      itemCount: value,
                      itemBuilder: (_, i) => Text('row-$i'),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      child: SizedBox(
                        width: 14,
                        child: UtenContentScrollbar(controller: controller),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(800);
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(UtenContentScrollbar));
      final position = controller.position;
      final track = rect.height - 32;
      final length =
          track *
          position.viewportDimension /
          (position.maxScrollExtent + position.viewportDimension);
      var fraction = position.pixels / position.maxScrollExtent;
      if (reverse) fraction = 1 - fraction;
      final center = rect.top + 16 + (track - length) * fraction + length / 2;
      final drag = await tester.startGesture(
        Offset(rect.center.dx, center),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(Offset(0, reverse ? -20 : 20));
      await tester.pump();
      final before = position.pixels;
      final oldRange = position.maxScrollExtent;
      count.value = 120;
      await tester.pump();
      // Include the rail rebuild used by a table's accepted page response.
      await tester.pump();
      await drag.moveBy(Offset(0, reverse ? -1 : 1));
      await tester.pump();
      final delta = position.pixels - before;
      debugPrint(
        'loading-thumb reverse=$reverse range=$oldRange->${position.maxScrollExtent} delta=$delta',
      );
      expect(delta, greaterThan(0));
      expect(
        delta,
        lessThan(30),
        reason:
            'one pointer pixel must not remap hundreds of content pixels after loading',
      );
      await drag.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
