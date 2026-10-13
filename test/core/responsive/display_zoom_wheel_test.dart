import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/display_zoom_pointer_binding.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';

class _ZoomTestBinding extends AutomatedTestWidgetsFlutterBinding
    with UtenDisplayZoomPointerEvents {}

void main() {
  _ZoomTestBinding();
  Future<void> pumpScroll(
    WidgetTester tester, {
    required ScrollController controller,
    required double fontFactor,
    Size window = const Size(1920, 1080),
    Axis axis = Axis.vertical,
    bool reverse = false,
    bool fillViewport = false,
    ScrollPhysics? physics,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const UtenScrollBehavior(),
        builder: (context, child) =>
            UtenDisplayZoomBox(fontFactor: fontFactor, child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            controller: controller,
            scrollDirection: axis,
            reverse: reverse,
            physics: physics,
            child: SizedBox(
              width: axis == Axis.horizontal
                  ? 5000
                  : fillViewport
                  ? double.infinity
                  : 200,
              height: axis == Axis.vertical
                  ? 5000
                  : fillViewport
                  ? double.infinity
                  : 200,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> wheel(
    WidgetTester tester,
    Offset delta, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    Offset at = const Offset(100, 100),
    void Function({required bool allowPlatformDefault})? onRespond,
  }) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: at,
        scrollDelta: delta,
        kind: kind,
        onRespond: onRespond,
      ),
    );
    await tester.pump();
  }

  for (final fontFactor in [0.75, 0.85, 1.0, 1.5, 2.0]) {
    testWidgets('字号 $fontFactor：滚轮的窗口位移恒为输入距离', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpScroll(tester, controller: controller, fontFactor: fontFactor);
      final responses = <bool>[];
      await wheel(
        tester,
        const Offset(0, 120),
        onRespond: ({required allowPlatformDefault}) =>
            responses.add(allowPlatformDefault),
      );
      expect(controller.offset * fontFactor, closeTo(120, 0.001));
      expect(responses, [false], reason: '一次输入只被消费一次，并告知浏览器已处理');
      await wheel(tester, const Offset(0, -30));
      expect(controller.offset * fontFactor, closeTo(90, 0.001));
    });
  }

  for (final factor in [0.75, 0.85, 1.0, 2.0]) {
    testWidgets('$factor: bottom-right wheel and Shift wheel normalize once', (
      tester,
    ) async {
      const window = Size(390, 1000);
      const at = Offset(388, 998);
      final vertical = ScrollController();
      final horizontal = ScrollController();
      addTearDown(vertical.dispose);
      addTearDown(horizontal.dispose);
      await pumpScroll(
        tester,
        controller: vertical,
        fontFactor: factor,
        window: window,
        fillViewport: true,
      );
      final responses = <bool>[];
      await wheel(
        tester,
        const Offset(0, 120),
        at: at,
        onRespond: ({required allowPlatformDefault}) =>
            responses.add(allowPlatformDefault),
      );
      expect(vertical.offset * factor, closeTo(120, 0.001));
      expect(responses, [false]);
      await pumpScroll(
        tester,
        controller: horizontal,
        fontFactor: factor,
        window: window,
        fillViewport: true,
        axis: Axis.horizontal,
      );
      final horizontalBefore = horizontal.offset;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await wheel(tester, const Offset(0, 120), at: at);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(
        (horizontal.offset - horizontalBefore) * factor,
        closeTo(120, 0.001),
      );
    });
  }

  testWidgets('宽屏仍按所选倍率：横滚、Shift 横滚和反向列表均换算一次', (tester) async {
    final controller = ScrollController(initialScrollOffset: 300);
    addTearDown(controller.dispose);
    await pumpScroll(
      tester,
      controller: controller,
      fontFactor: 1.5,
      window: const Size(2560, 1440),
      axis: Axis.horizontal,
      reverse: true,
    );
    await wheel(tester, const Offset(120, 0));
    expect(controller.offset, closeTo(220, 0.001));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await wheel(tester, const Offset(0, 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.offset, closeTo(220 - 100 / 1.5, 0.001));
  });

  testWidgets('触控板小增量保留精度；不能滚动时保留平台默认响应', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpScroll(tester, controller: controller, fontFactor: 2);
    await wheel(
      tester,
      const Offset(0, 1.25),
      kind: PointerDeviceKind.trackpad,
    );
    expect(controller.offset, closeTo(0.625, 0.0001));
    controller.jumpTo(controller.position.maxScrollExtent);
    final responses = <bool>[];
    await wheel(
      tester,
      const Offset(0, 120),
      onRespond: ({required allowPlatformDefault}) =>
          responses.add(allowPlatformDefault),
    );
    expect(responses, [true]);
  });

  testWidgets('手机整体放大仍保持滚轮窗口距离；禁用滚动仍生效', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpScroll(
      tester,
      controller: controller,
      fontFactor: 1.5,
      window: const Size(390, 844),
    );
    await wheel(tester, const Offset(0, 120));
    expect(controller.offset * 1.5, 120);
    await pumpScroll(
      tester,
      controller: controller,
      fontFactor: 2,
      physics: const NeverScrollableScrollPhysics(),
    );
    final before = controller.offset;
    await wheel(tester, const Offset(0, 120));
    expect(controller.offset, before);
  });
}
