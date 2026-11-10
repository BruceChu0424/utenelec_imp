import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drag the painted SDK thumb, allowing platform-specific cross-axis margins
/// and thickness. Counting/axis/overflow assertions remain with each caller.
Future<void> dragHorizontalScrollbarThumb(
  WidgetTester tester,
  Finder scrollbar, {
  double distance = 160,
}) async {
  final raw = find.descendant(
    of: scrollbar,
    matching: find.byWidgetPredicate((widget) => widget is RawScrollbar),
  );
  expect(raw, findsOneWidget);
  final painted = find
      .descendant(
        of: raw,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.foregroundPainter is ScrollbarPainter,
        ),
      )
      .first;
  final painter =
      tester.widget<CustomPaint>(painted).foregroundPainter!
          as ScrollbarPainter;
  final box = tester.renderObject<RenderBox>(painted);
  Rect? thumb;
  for (var y = math.max(0.5, box.size.height - 32); y < box.size.height; y++) {
    for (var x = 0.5; x < box.size.width; x++) {
      final point = Offset(x, y);
      if (painter.hitTestOnlyThumbInteractive(point, PointerDeviceKind.mouse)) {
        final sample = Rect.fromLTWH(x, y, 1, 1);
        thumb = thumb == null ? sample : thumb.expandToInclude(sample);
      }
    }
  }
  expect(thumb, isNotNull, reason: '横滚滑块必须已绘制且能命中真实鼠标手势');
  final gesture = await tester.startGesture(
    box.localToGlobal(thumb!.center),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(20, 0));
  await tester.pump();
  await gesture.moveBy(Offset(distance, 0));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}
