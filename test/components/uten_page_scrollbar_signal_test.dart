import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_scroll_signal_scope.dart';
import 'package:uten_imp/components/layout/uten_sticky_header.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

Finder _rail() => find.byKey(UtenPageScrollbarHost.railKey);
ScrollPosition _inner(WidgetTester tester) =>
    tester.widget<UtenContentScrollbar>(_rail()).controller.position;

Future<void> _wheel(
  WidgetTester tester,
  double delta, {
  bool atArrow = false,
}) async {
  final rect = tester.getRect(_rail());
  final at = Offset(rect.center.dx, atArrow ? rect.top + 5 : rect.center.dy);
  final pointer = TestPointer(7, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, delta)));
  await tester.pumpAndSettle(const Duration(milliseconds: 10));
}

Future<void> _pumpLinked(
  WidgetTester tester,
  ScrollController outer,
  double zoom,
) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      scrollBehavior: const UtenScrollBehavior(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: UtenDisplayZoomBox(fontFactor: zoom, child: child!),
      ),
      home: Scaffold(
        body: UtenPageScrollbarHost(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: UtenCollapsingHeaderScrollView(
              controller: outer,
              compactBreakpoint: 0,
              compactHeightBreakpoint: 0,
              collapsingHeader: const SizedBox(
                key: Key('linked-header'),
                height: 180,
              ),
              body: MasterDataTableView<String>(
                primary: true,
                columns: [
                  MasterColumnDef<String>(
                    key: 'name',
                    label: 'Name',
                    width: 240,
                    value: (row) => row,
                  ),
                ],
                items: List.generate(100, (i) => 'Row $i'),
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 10));
  expect(_rail(), findsOneWidget);
  expect(
    _barDelegate(tester),
    isNull,
    reason: 'The ordinary NestedScrollView keeps its existing controller path',
  );
  expect(
    tester.widget<UtenContentScrollbar>(_rail()).onPointerSignal,
    isNotNull,
  );
}

Object? _barDelegate(WidgetTester tester) =>
    tester.widget<UtenContentScrollbar>(_rail()).railDelegate;

class _HostSignalTestBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}

void main() {
  _HostSignalTestBinding();
  testWidgets(
    'scope chains run outer before inner once for transformed signal views',
    (tester) async {
      final order = <String>[];
      final deltas = <double>[];
      final outer = UtenScrollSignalController((event) {
        order.add('outer');
        deltas.add((event as PointerScrollEvent).scrollDelta.dy);
      });
      final inner = UtenScrollSignalController((event) {
        order.add('inner');
        deltas.add((event as PointerScrollEvent).scrollDelta.dy);
      });
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      UtenScrollSignalController? captured;
      await tester.pumpWidget(
        UtenScrollSignalScope(
          controller: outer,
          child: UtenScrollSignalScope(
            controller: inner,
            child: Builder(
              builder: (context) {
                captured = UtenScrollSignalScope.maybeOf(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      const event = PointerScrollEvent(scrollDelta: Offset(0, 75));
      captured!.dispatch(
        event.transformed(Matrix4.translationValues(20, 30, 0)),
      );
      captured!.dispatch(event);
      outer.dispatch(event);
      expect(order, ['outer', 'inner']);
      expect(deltas, [
        75,
        75,
      ], reason: 'Delegation never applies a second zoom conversion');
    },
  );

  for (final zoom in [1.0, 1.5, 2.0]) {
    testWidgets(
      'root rail returns from inner.min to the real nested header at zoom $zoom',
      (tester) async {
        final outer = ScrollController();
        addTearDown(outer.dispose);
        await _pumpLinked(tester, outer, zoom);
        outer.jumpTo(outer.position.maxScrollExtent);
        await tester.pumpAndSettle(const Duration(milliseconds: 10));
        _inner(tester).jumpTo(_inner(tester).minScrollExtent);
        final before = outer.offset;
        await _wheel(tester, -60 * zoom);
        expect(outer.offset, closeTo(before - 60, .01));
        expect(_inner(tester).pixels, _inner(tester).minScrollExtent);
        final shifted = outer.offset;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await _wheel(tester, 60 * zoom);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(
          outer.offset,
          shifted,
          reason: 'Shift wheel must not become another vertical event',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rail and arrow listeners do not bypass or double-consume the nested hold gate',
    (tester) async {
      final outer = ScrollController();
      addTearDown(outer.dispose);
      await _pumpLinked(tester, outer, 1);
      await _wheel(tester, 100);
      expect(outer.offset, 100);
      await _wheel(tester, 100);
      expect(outer.offset, 180);
      expect(_inner(tester).pixels, 0);
      await _wheel(tester, 140, atArrow: true);
      expect(
        _inner(tester).pixels,
        0,
        reason:
            'One 140px event remains below the 250px release threshold, even when arrow and rail both receive it',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await _wheel(tester, 100);
      expect(_inner(tester).pixels, closeTo(50, .01));
      await _wheel(tester, -200);
      expect(_inner(tester).pixels, 0);
      expect(outer.offset, 180);
      await _wheel(tester, -100, atArrow: true);
      expect(outer.offset, 180);
      await tester.pump(const Duration(milliseconds: 400));
      await _wheel(tester, -100);
      expect(outer.offset, closeTo(130, .01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('root rail reuses the real sticky gate and its pause window', (
    tester,
  ) async {
    final page = ScrollController();
    addTearDown(page.dispose);
    final stackKey = GlobalKey(),
        headerKey = GlobalKey(),
        bodyKey = GlobalKey();
    final tracker = UtenStickyHeaderTracker(
      stackKey: stackKey,
      headerKey: headerKey,
      bodyKey: bodyKey,
    );
    addTearDown(tracker.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        scrollBehavior: const UtenScrollBehavior(),
        home: Scaffold(
          body: UtenPageScrollbarHost(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: UtenStickyWheelGate(
                tracker: tracker,
                onEngage: (_) {},
                child: UtenVerticalScrollArea(
                  pageScrollbar: true,
                  controller: page,
                  child: ListView(
                    controller: page,
                    children: [
                      const SizedBox(height: 180),
                      Stack(
                        key: stackKey,
                        children: [
                          Column(
                            children: [
                              SizedBox(key: headerKey, height: 40),
                              SizedBox(key: bodyKey, height: 1800),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    expect(tracker.measure(), isTrue);
    expect(tracker.pinOffset, closeTo(180, .01));
    await _wheel(tester, 250);
    expect(page.offset, closeTo(180, .01));
    await _wheel(tester, 140, atArrow: true);
    expect(page.offset, closeTo(180, .01));
    await tester.pump(const Duration(milliseconds: 400));
    await _wheel(tester, 100);
    expect(page.offset, closeTo(280, .01));
    expect(tester.takeException(), isNull);
  });
}
