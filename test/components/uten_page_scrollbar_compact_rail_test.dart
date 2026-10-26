import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/components/layout/uten_vertical_scrollbar.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/core/theme/uten_scrollbar_style.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _headerKey = Key('compact-linked-header');
const _hostKey = Key('full-height-host');
Finder _rail() => find.byKey(UtenPageScrollbarHost.railKey);
UtenContentScrollbar _bar(WidgetTester tester) =>
    tester.widget<UtenContentScrollbar>(_rail());

class _CompactRailBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}

Future<void> _pumpCompact(
  WidgetTester tester,
  ScrollController outer, {
  double zoom = 1,
  ScrollController? left,
  FocusNode? focus,
  EdgeInsets safePadding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = const Size(1366, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Widget appFor(ScrollController page, {required bool hosted}) {
    final content = UtenPageEdgePadding(
      padding: const EdgeInsets.all(24),
      child: UtenCollapsingHeaderScrollView(
        controller: page,
        compactHeightBreakpoint: double.infinity,
        collapsingHeader: SizedBox(
          key: _headerKey,
          height: 420,
          child: focus == null ? null : TextField(focusNode: focus),
        ),
        body: Row(
          children: [
            if (left != null) ...[
              SizedBox(
                width: 180,
                child: UtenVerticalScrollArea(
                  controller: left,
                  child: ListView(
                    controller: left,
                    children: const [SizedBox(height: 1800)],
                  ),
                ),
              ),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: MasterDataTableView<String>(
                primary: true,
                columns: [
                  MasterColumnDef<String>(
                    key: 'name',
                    label: 'Name',
                    width: 240,
                    value: (row) => row,
                  ),
                ],
                items: List.generate(20, (i) => 'Row $i'),
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              ),
            ),
          ],
        ),
      ),
    );
    return MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      scrollBehavior: const UtenScrollBehavior(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: true, padding: safePadding),
        child: UtenDisplayZoomBox(fontFactor: zoom, child: child!),
      ),
      home: Scaffold(
        body: hosted
            ? UtenPageScrollbarHost(key: _hostKey, child: content)
            : content,
      ),
    );
  }

  // Measure the existing local automatic scrollbar +16 gutter without a Host.
  // The new page contract removes exactly this old local16, while keeping the
  // page24 window inset and the original left/top/height/vertical viewport.
  final baselineController = ScrollController();
  addTearDown(baselineController.dispose);
  await tester.pumpWidget(appFor(baselineController, hosted: false));
  await tester.pumpAndSettle(const Duration(milliseconds: 10));
  expect(_rail(), findsNothing);
  final originalHeader = tester.getRect(find.byKey(_headerKey));
  final originalViewport = baselineController.position.viewportDimension;
  expect(originalHeader.right, closeTo(1366 - 24 - 16 * zoom, .01));
  await tester.pumpWidget(appFor(outer, hosted: true));
  await tester.pumpAndSettle(const Duration(milliseconds: 10));
  expect(_rail(), findsOneWidget);
  expect(_bar(tester).railDelegate, isNotNull);
  final host = tester.getRect(find.byKey(_hostKey));
  final rail = tester.getRect(_rail());
  expect(rail.top, closeTo(host.top + safePadding.top, .01));
  expect(rail.bottom, closeTo(host.bottom - safePadding.bottom, .01));
  expect(rail.right, closeTo(host.right - safePadding.right - 2, .01));
  expect(rail.width, closeTo(14, .01));
  final header = tester.getRect(find.byKey(_headerKey));
  expect(header.left, originalHeader.left);
  expect(header.right, closeTo(host.right - 24, .01));
  expect(header.width - originalHeader.width, closeTo(16 * zoom, .01));
  expect(header.top, originalHeader.top);
  expect(header.height, originalHeader.height);
  expect(outer.position.viewportDimension, originalViewport);
}

({double center, double length}) _thumb(WidgetTester tester, double zoom) {
  final metrics = _bar(tester).railDelegate!.metrics!;
  final rect = tester.getRect(_rail());
  final arrow = UtenScrollbarStyle.arrowExtentForTrack(rect.height);
  final track = rect.height - 2 * arrow;
  final range = metrics.maxScrollExtent - metrics.minScrollExtent;
  final ratio =
      (metrics.viewportDimension / (range + metrics.viewportDimension)).clamp(
        .05,
        1.0,
      );
  final length = (track * ratio)
      .clamp(math.min(UtenScrollbarStyle.minimumThumbLength, track * .8), track)
      .toDouble();
  final fraction = (metrics.pixels - metrics.minScrollExtent) / range;
  return (
    center: rect.top + arrow + (track - length) * fraction + length / 2,
    length: length,
  );
}

void _expectOnlyOneMainRail(WidgetTester tester, ScrollController outer) {
  expect(_rail(), findsOneWidget);
  final innerController = _bar(tester).controller;
  for (final widget in tester.widgetList<UtenVerticalScrollbar>(
    find.byType(UtenVerticalScrollbar),
  )) {
    if (identical(widget.controller, outer) ||
        widget.controller.positions.any(innerController.positions.contains)) {
      expect(widget.visible, isFalse);
    }
  }
  for (final widget in tester.widgetList<UtenContentScrollbar>(
    find.byType(UtenContentScrollbar),
  )) {
    if (widget.key != UtenPageScrollbarHost.railKey &&
        widget.controller.positions.any(innerController.positions.contains)) {
      expect(widget.visible, isFalse);
    }
  }
}

Future<void> _wheel(WidgetTester tester, double delta) async {
  final pointer = TestPointer(71, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(_rail())));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  await tester.pumpAndSettle(const Duration(milliseconds: 10));
}

void main() {
  _CompactRailBinding();
  for (final zoom in [1.0, 1.5, 2.0]) {
    testWidgets(
      'compact rail drag is continuous through source handoff and reaches both ends at zoom $zoom',
      (tester) async {
        final outer = ScrollController();
        final focus = FocusNode();
        addTearDown(outer.dispose);
        addTearDown(focus.dispose);
        await _pumpCompact(tester, outer, zoom: zoom, focus: focus);
        focus.requestFocus();
        await tester.pump();
        final editorState = tester.state(find.byType(TextField));
        final initial = _bar(tester);
        expect(initial.controller.position, same(outer.position));
        final delegate = initial.railDelegate!;
        final initialTotal = delegate.metrics!.maxScrollExtent;
        final rect = tester.getRect(_rail());
        final thumb = _thumb(tester, zoom);
        final metrics = delegate.metrics!;
        final outerRange =
            outer.position.maxScrollExtent - outer.position.minScrollExtent;
        final totalRange = metrics.maxScrollExtent - metrics.minScrollExtent;
        // Choose a point beyond the real outer range at every zoom. The visual
        // midpoint is still inside the outer segment at2x with this tall header.
        final handoffFraction =
            (outerRange + (totalRange - outerRange) * .25) / totalRange;
        final thumbTravel = rect.height - 32 - thumb.length;
        final gesture = await tester.startGesture(
          Offset(rect.center.dx, thumb.center),
          kind: PointerDeviceKind.mouse,
        );
        // A first move wins the drag recognizer; DragStartBehavior.start does
        // not deliver that whole movement as an onVerticalDragUpdate.
        await gesture.moveBy(Offset(0, 24 * zoom));
        await tester.pump();
        await gesture.moveTo(
          Offset(
            rect.center.dx,
            rect.top + 16 + handoffFraction * thumbTravel + thumb.length / 2,
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 10));
        expect(_bar(tester).railDelegate, same(delegate));
        expect(outer.offset, closeTo(outer.position.maxScrollExtent, .01));
        expect(
          delegate.metrics!.pixels,
          closeTo(metrics.minScrollExtent + handoffFraction * totalRange, .01),
        );
        expect(_bar(tester).controller.position, isNot(same(outer.position)));
        final inner = _bar(tester).controller.position;
        expect(delegate.metrics!.pixels, greaterThan(0));
        expect(delegate.metrics!.maxScrollExtent, initialTotal);
        // Keep the same pointer down across the automatic outer -> table owner
        // change. A second drag must not be necessary to reach the last row.
        await gesture.moveTo(
          Offset(rect.center.dx, rect.bottom - 16 - thumb.length / 2),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 10));
        expect(outer.offset, closeTo(outer.position.maxScrollExtent, .01));
        expect(inner.pixels, closeTo(inner.maxScrollExtent, .01));
        expect(
          delegate.metrics!.pixels,
          closeTo(delegate.metrics!.maxScrollExtent, 1e-6),
        );
        expect(find.text('Row 19').hitTestable(), findsOneWidget);
        _expectOnlyOneMainRail(tester, outer);
        await gesture.moveTo(
          Offset(rect.center.dx, rect.top + 16 + thumb.length / 2),
        );
        await gesture.up();
        await tester.pumpAndSettle(const Duration(milliseconds: 10));
        expect(outer.offset, outer.position.minScrollExtent);
        expect(inner.pixels, inner.minScrollExtent);
        expect(tester.getTopLeft(find.byKey(_headerKey)).dy, 24 * zoom);
        expect(tester.state(find.byType(TextField)), same(editorState));
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'compact arrows hold across outer and inner at a 32px window step at zoom $zoom',
      (tester) async {
        final outer = ScrollController();
        addTearDown(outer.dispose);
        await _pumpCompact(tester, outer, zoom: zoom);
        final delegate = _bar(tester).railDelegate!;
        final rect = tester.getRect(_rail());
        final down = await tester.startGesture(
          Offset(rect.center.dx, rect.bottom - 5 * zoom),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(delegate.metrics!.pixels * zoom, closeTo(32, .01));
        // Pump each repeat so the real owner changes while the arrow remains
        // pressed; changing the local controller must not cancel the hold.
        await tester.pump(const Duration(milliseconds: 300));
        for (
          var i = 0;
          i < 100 &&
              delegate.metrics!.pixels < delegate.metrics!.maxScrollExtent;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          delegate.metrics!.pixels,
          closeTo(delegate.metrics!.maxScrollExtent, 1e-6),
        );
        expect(outer.offset, outer.position.maxScrollExtent);
        final inner = _bar(tester).controller.position;
        expect(inner.pixels, inner.maxScrollExtent);
        expect(find.text('Row 19').hitTestable(), findsOneWidget);
        await down.up();
        await tester.pump();
        final up = await tester.startGesture(
          Offset(rect.center.dx, rect.top + 5 * zoom),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 300));
        for (
          var i = 0;
          i < 100 &&
              delegate.metrics!.pixels > delegate.metrics!.minScrollExtent;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await up.up();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          delegate.metrics!.pixels,
          closeTo(delegate.metrics!.minScrollExtent, 1e-6),
        );
        expect(outer.offset, outer.position.minScrollExtent);
        expect(inner.pixels, inner.minScrollExtent);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compact combined rail preserves wheel gate pause and Shift', (
    tester,
  ) async {
    final outer = ScrollController();
    final left = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(left.dispose);
    await _pumpCompact(tester, outer, left: left);
    final delegate = _bar(tester).railDelegate!;
    await _wheel(tester, 1000);
    expect(outer.offset, outer.position.maxScrollExtent);
    final inner = _bar(tester).controller.position;
    expect(inner.pixels, inner.minScrollExtent);
    await _wheel(tester, 140);
    expect(inner.pixels, inner.minScrollExtent);
    await tester.pump(const Duration(milliseconds: 400));
    await _wheel(tester, 100);
    expect(inner.pixels, closeTo(inner.minScrollExtent + 50, .01));
    final pixels = delegate.metrics!.pixels;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _wheel(tester, 100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(delegate.metrics!.pixels, pixels);
    _expectOnlyOneMainRail(tester, outer);
    final leftBar = tester.widget<UtenContentScrollbar>(
      find.byWidgetPredicate(
        (widget) =>
            widget is UtenContentScrollbar &&
            identical(widget.controller, left),
      ),
    );
    expect(leftBar.visible, isTrue);
    expect(left.offset, 0);
    expect(tester.takeException(), isNull);
  });
}
