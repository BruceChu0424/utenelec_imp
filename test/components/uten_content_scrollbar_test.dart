import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';

const _viewportKey = ValueKey('viewport');
const _viewportHeight = 400.0;
const _bottomInset = 80.0;

Widget _harness(
  ScrollController controller, {
  bool reverse = false,
  bool visible = true,
  double height = _viewportHeight,
  double contentHeight = 2000,
  double bottomInset = _bottomInset,
  VoidCallback? onContentTap,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        key: _viewportKey,
        width: 300,
        height: height,
        child: ScrollConfiguration(
          behavior: const MaterialScrollBehavior().copyWith(scrollbars: false),
          child: Stack(
            children: [
              ListView(
                controller: controller,
                reverse: reverse,
                padding: EdgeInsets.only(bottom: bottomInset),
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onContentTap,
                    child: SizedBox(height: contentHeight),
                  ),
                ],
              ),
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: 14,
                child: UtenContentScrollbar(
                  controller: controller,
                  visible: visible,
                  bottomInset: bottomInset,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

Offset _point(WidgetTester tester, double y, {double x = 293}) =>
    tester.getTopLeft(find.byKey(_viewportKey)) + Offset(x, y);

Future<void> _pump(WidgetTester tester, ScrollController controller) async {
  await tester.pumpWidget(_harness(controller));
  // Rebuild once with dimensions available so the pre-fix implementation also
  // paints a thumb; these interaction regressions must fail for pointer handling.
  await tester.pumpWidget(_harness(controller));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'constraint-only resize reveals a newly scrollable cached child',
    (tester) async {
      final controller = ScrollController();
      final height = ValueNotifier<double>(500);
      addTearDown(controller.dispose);
      addTearDown(height.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: ValueListenableBuilder<double>(
              valueListenable: height,
              child: _harness(
                controller,
                height: double.infinity,
                contentHeight: 380,
                bottomInset: 0,
              ),
              builder: (_, value, child) =>
                  SizedBox(width: 300, height: value, child: child),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.position.maxScrollExtent, 0);
      height.value = 200;
      await tester.pumpAndSettle();
      expect(controller.position.maxScrollExtent, 180);
      await tester.tapAt(_point(tester, 190), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(controller.offset, 160);
    },
  );

  testWidgets(
    'bottom padding cannot leave a scrollable view with a full-track thumb',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(controller, contentHeight: 380));
      await tester.pumpAndSettle();
      expect(controller.position.maxScrollExtent, 60);
      final gesture = await tester.startGesture(
        _point(tester, 10),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 80));
      await tester.pump();
      expect(controller.offset, 60);
      await gesture.up();
    },
  );

  testWidgets(
    'thumb is interactive after initial layout without a prior scroll',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_harness(controller));
      await tester.pumpAndSettle();
      await tester.tapAt(_point(tester, 290), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(_viewportHeight * 0.8, 1));
    },
  );

  testWidgets(
    'mouse drag moves the thumb and clamps at both scroll boundaries',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await _pump(tester, controller);
      final gesture = await tester.startGesture(
        _point(tester, 32),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 134.4));
      await tester.pump();
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent / 2, 1),
      );
      await gesture.moveBy(const Offset(0, 600));
      await tester.pump();
      expect(controller.offset, controller.position.maxScrollExtent);
      await gesture.moveTo(_point(tester, -100));
      await tester.pump();
      expect(controller.offset, controller.position.minScrollExtent);
      await gesture.up();
    },
  );

  testWidgets('track clicks page down and back up without activating content', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var contentTaps = 0;
    await tester.pumpWidget(
      _harness(controller, onContentTap: () => contentTaps++),
    );
    await tester.pumpWidget(
      _harness(controller, onContentTap: () => contentTaps++),
    );
    await tester.pumpAndSettle();

    await tester.tapAt(_point(tester, 290), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(_viewportHeight * 0.8, 1));
    expect(contentTaps, 0);
    await tester.tapAt(_point(tester, 10), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(contentTaps, 0);
  });

  testWidgets('content and the bottom clearance remain clickable', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var contentTaps = 0;
    await tester.pumpWidget(
      _harness(controller, onContentTap: () => contentTaps++),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(_point(tester, 150, x: 280));
    await tester.tapAt(_point(tester, 360));
    expect(contentTaps, 2);
    expect(controller.offset, 0);
  });

  testWidgets('wheel on the thumb still reaches the content scrollable', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: _point(tester, 32),
        scrollDelta: const Offset(0, 40),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, 40);
  });

  testWidgets('reverse scrolling places the thumb at the bottom and drags up', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_harness(controller, reverse: true));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      _point(tester, 294.4),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -134.4));
    await tester.pump();
    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent / 2, 1),
    );
    await gesture.up();
    await tester.tapAt(_point(tester, 10), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(840 + 320, 1));
  });

  testWidgets(
    'bottom of the painted thumb stays above the reserved clearance',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await _pump(tester, controller);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final paint = find.descendant(
        of: find.byType(UtenContentScrollbar),
        matching: find.byType(CustomPaint),
      );
      expect(tester.getSize(paint).height, 320);
      expect(
        tester.renderObject(paint),
        paints..rrect(
          rrect: RRect.fromRectAndRadius(
            const Rect.fromLTWH(5, 268.8, 6, 51.2),
            const Radius.circular(3),
          ),
        ),
      );
    },
  );

  testWidgets('resized viewport and content use the new thumb travel', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    await tester.pumpWidget(
      _harness(controller, height: 300, contentHeight: 3000, bottomInset: 60),
    );
    await tester.pumpAndSettle();
    // New track: 240; thumb: 19.2; 110.4 px is half of the thumb's travel.
    final gesture = await tester.startGesture(
      _point(tester, 9.6),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 110.4));
    await tester.pump();
    expect(
      controller.offset,
      closeTo(controller.position.maxScrollExtent / 2, 1),
    );
    await gesture.up();
  });

  testWidgets(
    'controller replacement cancels the old drag and drives the new view',
    (tester) async {
      final first = ScrollController();
      final second = ScrollController();
      addTearDown(second.dispose);
      await _pump(tester, first);
      final gesture = await tester.startGesture(
        _point(tester, 32),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(first.offset, greaterThan(0));

      await tester.pumpWidget(_harness(second));
      await tester.pumpAndSettle();
      first.dispose();
      final newOffset = second.offset;
      await gesture.moveBy(const Offset(0, 60));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(second.offset, newOffset);
      second.jumpTo(0);
      await tester.pump();
      await tester.tapAt(_point(tester, 290), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(second.offset, closeTo(320, 1));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hidden, non-scrollable and fully reserved tracks pass through', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var taps = 0;
    for (final settings in [
      (visible: false, height: 400.0, content: 2000.0, inset: 80.0),
      (visible: true, height: 400.0, content: 300.0, inset: 0.0),
      (visible: true, height: 60.0, content: 2000.0, inset: 80.0),
    ]) {
      await tester.pumpWidget(
        _harness(
          controller,
          visible: settings.visible,
          height: settings.height,
          contentHeight: settings.content,
          bottomInset: settings.inset,
          onContentTap: () => taps++,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(_point(tester, 32), kind: PointerDeviceKind.mouse);
      expect(controller.offset, 0);
    }
    expect(taps, 3);
    expect(tester.takeException(), isNull);
  });
}
