import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_scroll_gutter.dart';
import 'package:uten_imp/components/layout/uten_vertical_scrollbar.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';

enum _Kind { sdk, custom }

final _up = find.byKey(const ValueKey('uten-scrollbar-up'));
final _down = find.byKey(const ValueKey('uten-scrollbar-down'));

Future<Color> _pixel(WidgetTester tester, GlobalKey key, Offset offset) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = (await image.toByteData())!;
    final index = (offset.dy.floor() * image.width + offset.dx.floor()) * 4;
    final color = Color.fromARGB(
      data.getUint8(index + 3),
      data.getUint8(index),
      data.getUint8(index + 1),
      data.getUint8(index + 2),
    );
    image.dispose();
    return color;
  }))!;
}

Widget _app(
  _Kind kind,
  ScrollController controller,
  ValueNotifier<bool> visible, {
  double contentHeight = 2400,
  double zoom = 1,
  TextEditingController? editor,
  FocusNode? editorFocus,
}) => MaterialApp(
  scrollBehavior: const UtenScrollBehavior(),
  theme: ThemeData(platform: TargetPlatform.windows),
  builder: (context, child) =>
      UtenDisplayZoomBox(fontFactor: zoom, child: child!),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 300,
        height: 300,
        child: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, shown, _) {
            final list = ListView(
              key: const Key('arrow-content'),
              controller: controller,
              primary: false,
              padding: EdgeInsets.zero,
              children: [
                if (editor != null)
                  TextField(
                    key: const Key('arrow-editor'),
                    controller: editor,
                    focusNode: editorFocus,
                  ),
                SizedBox(height: contentHeight),
              ],
            );
            if (kind == _Kind.sdk) {
              return UtenVerticalScrollbar(
                controller: controller,
                visible: shown,
                child: UtenScrollGutter(child: list),
              );
            }
            return UtenScrollbarOwnerScope(
              controller: controller,
              child: Stack(
                children: [
                  UtenScrollGutter(child: list),
                  Positioned(
                    top: 0,
                    right: 0,
                    bottom: 0,
                    width: 16,
                    child: UtenContentScrollbar(
                      controller: controller,
                      visible: shown,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  ),
);

void main() {
  for (final kind in _Kind.values) {
    testWidgets('$kind arrow hover stays inside the existing 16 px lane', (
      tester,
    ) async {
      final controller = ScrollController();
      final visible = ValueNotifier(true);
      final capture = GlobalKey();
      addTearDown(controller.dispose);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        RepaintBoundary(key: capture, child: _app(kind, controller, visible)),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(150, 150));
      await tester.pumpAndSettle();
      final button = tester.getRect(_down);
      final inside = button.topLeft + const Offset(2, 2);
      final outside = button.topLeft + const Offset(-1, 2);
      final idleInside = await _pixel(tester, capture, inside);
      final idleOutside = await _pixel(tester, capture, outside);
      await mouse.moveTo(button.center);
      await tester.pumpAndSettle();
      expect(await _pixel(tester, capture, inside), isNot(idleInside));
      expect(await _pixel(tester, capture, outside), idleOutside);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind arrows step once and disable exactly at each boundary', (
      tester,
    ) async {
      final controller = ScrollController();
      final visible = ValueNotifier(true);
      addTearDown(controller.dispose);
      addTearDown(visible.dispose);
      await tester.pumpWidget(_app(kind, controller, visible));
      await tester.pumpAndSettle();
      expect(tester.getSize(_up), const Size(16, 16));
      expect(tester.widget<Semantics>(_up).properties.enabled, isFalse);
      expect(tester.widget<Semantics>(_down).properties.enabled, isTrue);
      await tester.tap(_down, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        closeTo(32, .001),
        reason: 'An arrow must not also trigger SDK track-page scrolling',
      );
      expect(tester.widget<Semantics>(_up).properties.enabled, isTrue);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(tester.widget<Semantics>(_down).properties.enabled, isFalse);
      final end = controller.offset;
      await tester.tap(_down, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(controller.offset, end);
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(_up, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$kind held arrow repeats after 300 ms and stops immediately on release',
      (tester) async {
        final controller = ScrollController();
        final visible = ValueNotifier(true);
        addTearDown(controller.dispose);
        addTearDown(visible.dispose);
        await tester.pumpWidget(_app(kind, controller, visible));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(_down),
          kind: PointerDeviceKind.mouse,
        );
        expect(controller.offset, closeTo(32, .001));
        await tester.pump(const Duration(milliseconds: 299));
        expect(controller.offset, closeTo(32, .001));
        await tester.pump(const Duration(milliseconds: 1));
        expect(controller.offset, closeTo(64, .001));
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.offset, closeTo(96, .001));
        await gesture.up();
        await tester.pump(const Duration(seconds: 1));
        expect(controller.offset, closeTo(96, .001));
        expect(tester.takeException(), isNull);
      },
    );

    for (final stop in ['cancel', 'leave', 'hide']) {
      testWidgets('$kind held arrow stops on $stop', (tester) async {
        final controller = ScrollController();
        final visible = ValueNotifier(true);
        addTearDown(controller.dispose);
        addTearDown(visible.dispose);
        await tester.pumpWidget(_app(kind, controller, visible));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(_down),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 350));
        if (stop == 'cancel') {
          await gesture.cancel();
        } else if (stop == 'leave') {
          await gesture.moveTo(const Offset(150, 150));
        } else {
          visible.value = false;
          await tester.pump();
        }
        final stopped = controller.offset;
        await tester.pump(const Duration(seconds: 1));
        expect(controller.offset, stopped);
        if (stop != 'cancel') await gesture.up();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      '$kind unmount cancels the initial hold timer without waiting for it',
      (tester) async {
        final controller = ScrollController();
        final visible = ValueNotifier(true);
        addTearDown(controller.dispose);
        addTearDown(visible.dispose);
        await tester.pumpWidget(_app(kind, controller, visible));
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(_down),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await gesture.up();
        expect(tester.takeException(), isNull);
        // testWidgets also rejects pending timers at completion: the hold must
        // cancel during disposal rather than waiting for the next timer tick.
      },
    );

    testWidgets(
      '$kind arrows support keyboard activation and window-pixel zoom compensation',
      (tester) async {
        final controller = ScrollController();
        final visible = ValueNotifier(true);
        addTearDown(controller.dispose);
        addTearDown(visible.dispose);
        await tester.pumpWidget(_app(kind, controller, visible, zoom: 1.5));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(32 / 1.5, .001));
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(64 / 1.5, .001));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(32 / 1.5, .001));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$kind hiding a source rail preserves the exact scroll position, editor and focus',
      (tester) async {
        final controller = ScrollController();
        final visible = ValueNotifier(true);
        final text = TextEditingController();
        final focus = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(visible.dispose);
        addTearDown(text.dispose);
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          _app(kind, controller, visible, editor: text, editorFocus: focus),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('arrow-editor')), '未保存草稿');
        final position = controller.position;
        expect(focus.hasFocus, isTrue);
        visible.value = false;
        await tester.pumpAndSettle();
        expect(_up, findsNothing);
        expect(_down, findsNothing);
        expect(controller.position, same(position));
        expect(text.text, '未保存草稿');
        expect(focus.hasFocus, isTrue);
        visible.value = true;
        await tester.pumpAndSettle();
        expect(controller.position, same(position));
        expect(text.text, '未保存草稿');
        expect(focus.hasFocus, isTrue);
        expect(_down, findsOneWidget);
      },
    );

    testWidgets('$kind content contraction refreshes arrows after layout', (
      tester,
    ) async {
      final controller = ScrollController();
      final visible = ValueNotifier(true);
      addTearDown(controller.dispose);
      addTearDown(visible.dispose);
      await tester.pumpWidget(_app(kind, controller, visible));
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _app(kind, controller, visible, contentHeight: 500),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
      expect(tester.widget<Semantics>(_down).properties.enabled, isFalse);
      expect(tester.widget<Semantics>(_up).properties.enabled, isTrue);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(_app(kind, controller, visible));
      await tester.pumpAndSettle();
      expect(tester.widget<Semantics>(_down).properties.enabled, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$kind no-overflow has neither arrow semantics nor pointer targets',
      (tester) async {
        final controller = ScrollController();
        final visible = ValueNotifier(true);
        addTearDown(controller.dispose);
        addTearDown(visible.dispose);
        await tester.pumpWidget(
          _app(kind, controller, visible, contentHeight: 100),
        );
        await tester.pumpAndSettle();
        expect(controller.position.maxScrollExtent, 0);
        expect(_up, findsNothing);
        expect(_down, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
