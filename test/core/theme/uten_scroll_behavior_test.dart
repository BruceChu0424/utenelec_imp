import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_grid_page_scrollbar.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';

Widget _app(Widget child, {TargetPlatform platform = TargetPlatform.windows}) =>
    MaterialApp(
      scrollBehavior: const UtenScrollBehavior(),
      theme: ThemeData(
        platform: platform,
        scrollbarTheme: const ScrollbarThemeData(
          thickness: WidgetStatePropertyAll(10),
        ),
      ),
      home: Scaffold(body: child),
    );

Future<void> _dragThumb(WidgetTester tester, Finder view) async {
  final rect = tester.getRect(view);
  final gesture = await tester.startGesture(
    Offset(rect.right - 5, rect.top + 14),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(0, 20));
  await tester.pump();
  await gesture.moveBy(const Offset(0, 150));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in TargetPlatform.values) {
    testWidgets('overflow is immediately draggable on $platform', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final height = ValueNotifier<double>(100);
      addTearDown(height.dispose);
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 350,
            height: 300,
            child: ValueListenableBuilder<double>(
              valueListenable: height,
              builder: (_, value, _) => SingleChildScrollView(
                key: const ValueKey('page-scroll'),
                controller: controller,
                child: SizedBox(height: value),
              ),
            ),
          ),
          platform: platform,
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.position.maxScrollExtent, 0);
      height.value = 2400;
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((widget) => widget is RawScrollbar),
        findsOneWidget,
      );
      await _dragThumb(tester, find.byKey(const ValueKey('page-scroll')));
      expect(controller.offset, greaterThan(600));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shared primary positions have independently draggable bars', (
    tester,
  ) async {
    final primary = ScrollController();
    addTearDown(primary.dispose);
    await tester.pumpWidget(
      _app(
        PrimaryScrollController(
          controller: primary,
          child: Row(
            children: [
              for (var index = 0; index < 2; index++)
                SizedBox(
                  width: 300,
                  height: 300,
                  child: ListView.builder(
                    key: ValueKey('list-$index'),
                    primary: true,
                    itemExtent: 40,
                    itemCount: 100,
                    itemBuilder: (_, row) => Text('$index/$row'),
                  ),
                ),
            ],
          ),
        ),
        platform: TargetPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    expect(primary.positions.length, 2);
    final positions = primary.positions.toList();
    await _dragThumb(tester, find.byKey(const ValueKey('list-0')));
    expect(positions[0].pixels, greaterThan(600));
    expect(positions[1].pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'explicit scrollbar keeps one owner while nested view gets a bar',
    (tester) async {
      final outer = ScrollController();
      final inner = ScrollController();
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      await tester.pumpWidget(
        _app(
          Scrollbar(
            controller: outer,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: outer,
              child: Column(
                children: [
                  SizedBox(
                    height: 200,
                    child: ListView.builder(
                      controller: inner,
                      itemCount: 100,
                      itemBuilder: (_, i) => Text('item $i'),
                    ),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scrollbar), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('document page bar is draggable before its table is pinned', (
    tester,
  ) async {
    final controller = ScrollController();
    final pinned = ValueNotifier(false);
    addTearDown(controller.dispose);
    addTearDown(pinned.dispose);
    await tester.pumpWidget(
      _app(
        SizedBox(
          key: const ValueKey('document'),
          width: 350,
          height: 300,
          child: UtenGridPageScrollbar(
            controller: controller,
            pinned: pinned,
            bottomInset: 0,
            child: ListView(
              controller: controller,
              children: const [SizedBox(height: 2400)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Scrollbar), findsNothing);
    expect(find.byType(UtenContentScrollbar), findsOneWidget);
    await _dragThumb(tester, find.byKey(const ValueKey('document')));
    expect(controller.offset, greaterThan(600));
    expect(pinned.value, isFalse);
    expect(tester.takeException(), isNull);
  });
}
