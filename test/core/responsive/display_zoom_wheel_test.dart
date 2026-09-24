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
              width: axis == Axis.horizontal ? 5000 : 200,
              height: axis == Axis.vertical ? 5000 : 200,
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
    void Function({required bool allowPlatformDefault})? onRespond,
  }) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: const Offset(100, 100),
        scrollDelta: delta,
        kind: kind,
        onRespond: onRespond,
      ),
    );
    await tester.pump();
  }

  for (final fontFactor in [0.85, 1.0, 1.5, 2.0]) {
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

  testWidgets('宽屏自动放大与字号叠加：横滚、Shift 横滚和反向列表均换算一次', (tester) async {
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
    // 2560 / 1920 * 1.5 = 2。
    await wheel(tester, const Offset(120, 0));
    expect(controller.offset, closeTo(240, 0.001));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await wheel(tester, const Offset(0, 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.offset, closeTo(190, 0.001));
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

  testWidgets('手机只放大文字时不改变滚轮距离；禁用滚动仍生效', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pumpScroll(
      tester,
      controller: controller,
      fontFactor: 1.5,
      window: const Size(390, 844),
    );
    await wheel(tester, const Offset(0, 120));
    expect(controller.offset, 120);
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
