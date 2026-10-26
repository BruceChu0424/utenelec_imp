import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_scroll_scope.dart';
import 'package:uten_imp/components/layout/uten_scroll_gutter.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/components/layout/uten_vertical_scrollbar.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/core/theme/uten_scrollbar_style.dart';

enum _Mode { automatic, sdk, custom }

Widget _harness(
  ScrollController controller,
  ValueNotifier<double> contentHeight,
  GlobalKey captureKey, {
  required _Mode mode,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
  bool withScaffold = true,
}) {
  final list = ValueListenableBuilder<double>(
    valueListenable: contentHeight,
    builder: (_, height, _) => ListView(
      controller: controller,
      primary: false,
      padding: EdgeInsets.zero,
      children: [SizedBox(height: height)],
    ),
  );
  final body = switch (mode) {
    _Mode.automatic => list,
    _Mode.sdk => UtenVerticalScrollbar(
      controller: controller,
      child: UtenScrollGutter(child: list),
    ),
    _Mode.custom => UtenVerticalScrollArea(controller: controller, child: list),
  };
  final surface = Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 300,
      height: 300,
      child: RepaintBoundary(
        key: captureKey,
        child: ColoredBox(color: Colors.white, child: body),
      ),
    ),
  );
  return MaterialApp(
    scrollBehavior: const UtenScrollBehavior(),
    theme: ThemeData(platform: TargetPlatform.windows, brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: withScaffold ? Scaffold(body: surface) : surface,
  );
}

Future<Color> _pixel(WidgetTester tester, GlobalKey key, int x, int y) async {
  final result = await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = (await image.toByteData())!;
    final offset = (y * image.width + x) * 4;
    final color = Color.fromARGB(
      bytes.getUint8(offset + 3),
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
    image.dispose();
    return color;
  });
  return result!;
}

void main() {
  testWidgets(
    'custom owner receives metrics without Scaffold and releases its listener',
    (tester) async {
      final controller = ScrollController();
      final height = ValueNotifier<double>(100);
      final key = GlobalKey();
      addTearDown(controller.dispose);
      addTearDown(height.dispose);
      await tester.pumpWidget(
        _harness(
          controller,
          height,
          key,
          mode: _Mode.custom,
          withScaffold: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsNothing);
      expect(await _pixel(tester, key, 285, 200), Colors.white);
      height.value = 1800;
      await tester.pumpAndSettle();
      expect(
        await _pixel(tester, key, 285, 200),
        UtenScrollbarStyle.visuals(Brightness.light).trackColor,
      );
      height.value = 100;
      await tester.pumpAndSettle();
      expect(await _pixel(tester, key, 285, 200), Colors.white);
      await tester.pumpWidget(const SizedBox.shrink());
      height.value = 1800;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in _Mode.values) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '$mode $brightness paints thumb and track only with overflow',
        (tester) async {
          final controller = ScrollController();
          final height = ValueNotifier<double>(100);
          final key = GlobalKey();
          addTearDown(controller.dispose);
          addTearDown(height.dispose);
          await tester.pumpWidget(
            _harness(
              controller,
              height,
              key,
              mode: mode,
              brightness: brightness,
            ),
          );
          await tester.pumpAndSettle();
          expect(await _pixel(tester, key, 285, 200), Colors.white);
          expect(await _pixel(tester, key, 292, 20), Colors.white);

          height.value = 1800;
          await tester.pumpAndSettle();
          final visual = UtenScrollbarStyle.visuals(brightness);
          expect(await _pixel(tester, key, 285, 200), visual.trackColor);
          expect(await _pixel(tester, key, 292, 20), visual.thumbColor);

          height.value = 100;
          await tester.pumpAndSettle();
          expect(await _pixel(tester, key, 285, 200), Colors.white);
          expect(await _pixel(tester, key, 292, 20), Colors.white);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$mode hover animates the capsule inside the same 16 px lane', (
      tester,
    ) async {
      final controller = ScrollController();
      final height = ValueNotifier<double>(1800);
      final key = GlobalKey();
      addTearDown(controller.dispose);
      addTearDown(height.dispose);
      await tester.pumpWidget(_harness(controller, height, key, mode: mode));
      await tester.pumpAndSettle();
      final normal = UtenScrollbarStyle.visuals(Brightness.light);
      final hover = UtenScrollbarStyle.visuals(Brightness.light, emphasis: 1);
      expect(await _pixel(tester, key, 286, 25), normal.trackColor);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(150, 150));
      await mouse.moveTo(const Offset(292, 25));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final middle = await _pixel(tester, key, 292, 25);
      expect(middle, isNot(normal.thumbColor));
      expect(middle, isNot(hover.thumbColor));
      await tester.pumpAndSettle();
      expect(await _pixel(tester, key, 286, 25), hover.thumbColor);
      expect(
        await _pixel(tester, key, 283, 25),
        Colors.white,
        reason: 'Hover must never expand into content left of the lane',
      );
      await mouse.moveTo(const Offset(150, 150));
      await tester.pumpAndSettle();
      expect(await _pixel(tester, key, 286, 25), normal.trackColor);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$mode reduced motion applies hover without animated intermediate paint',
      (tester) async {
        final controller = ScrollController();
        final height = ValueNotifier<double>(1800);
        final key = GlobalKey();
        addTearDown(controller.dispose);
        addTearDown(height.dispose);
        await tester.pumpWidget(
          _harness(controller, height, key, mode: mode, reduceMotion: true),
        );
        await tester.pumpAndSettle();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(150, 150));
        await mouse.moveTo(const Offset(292, 25));
        await tester.pump();
        final hover = UtenScrollbarStyle.visuals(Brightness.light, emphasis: 1);
        expect(await _pixel(tester, key, 292, 25), hover.thumbColor);
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'local vertical styling preserves nested horizontal and dropdown themes',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      const original = ScrollbarThemeData(thickness: WidgetStatePropertyAll(7));
      double? nestedThickness;
      double? dropdownThickness;
      await tester.pumpWidget(
        MaterialApp(
          home: ScrollbarTheme(
            data: original,
            child: UtenVerticalScrollbar(
              controller: controller,
              child: SingleChildScrollView(
                controller: controller,
                child: Column(
                  children: [
                    Builder(
                      builder: (context) {
                        nestedThickness = ScrollbarTheme.of(
                          context,
                        ).thickness?.resolve({});
                        return const SizedBox(height: 20);
                      },
                    ),
                    UtenDropdownScrollScope(
                      child: Builder(
                        builder: (context) {
                          dropdownThickness = ScrollbarTheme.of(
                            context,
                          ).thickness?.resolve({});
                          return const SizedBox(height: 20);
                        },
                      ),
                    ),
                    const SizedBox(height: 1800),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(nestedThickness, 7);
      expect(dropdownThickness, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
