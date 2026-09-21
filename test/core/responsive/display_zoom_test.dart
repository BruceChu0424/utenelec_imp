// 整体缩放（UtenDisplayZoom / UtenDisplayZoomBox）测试。
//
// 1) 倍率拆分：宽屏自动放大、字号档整体缩放、手机只放大文字、平板画布保底 600；
// 2) 容器：2560 宽窗口按 1920 画布布局并整体放大——MediaQuery 尺寸换算、渲染尺寸
//    放大 zoom 倍、点击命中按窗口坐标反算到画布；≤1920 且标准字号不套 Transform。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';

void main() {
  group('UtenDisplayZoom.resolve', () {
    test('≤1920 宽且标准字号：不缩放', () {
      expect(
        UtenDisplayZoom.resolve(windowWidth: 1920, fontFactor: 1),
        const UtenZoomResolution(zoom: 1, textScale: 1),
      );
      expect(
        UtenDisplayZoom.resolve(windowWidth: 1536, fontFactor: 1),
        const UtenZoomResolution(zoom: 1, textScale: 1),
      );
    });

    test('宽屏自动放大：2560 → 4/3，3840 封顶 2.0', () {
      final r = UtenDisplayZoom.resolve(windowWidth: 2560, fontFactor: 1);
      expect(r.zoom, closeTo(2560 / 1920, 1e-9));
      expect(r.textScale, 1);
      expect(
        UtenDisplayZoom.resolve(windowWidth: 3840, fontFactor: 1).zoom,
        2.0,
      );
      expect(
        UtenDisplayZoom.resolve(windowWidth: 5120, fontFactor: 1).zoom,
        2.0,
      );
    });

    test('桌面字号档 = 整体缩放（文字不再单独放大）', () {
      expect(
        UtenDisplayZoom.resolve(windowWidth: 1920, fontFactor: 1.5),
        const UtenZoomResolution(zoom: 1.5, textScale: 1),
      );
      expect(
        UtenDisplayZoom.resolve(windowWidth: 1920, fontFactor: 0.85),
        const UtenZoomResolution(zoom: 0.85, textScale: 1),
      );
      // 宽屏 × 字号档相乘。
      final r = UtenDisplayZoom.resolve(windowWidth: 2560, fontFactor: 1.5);
      expect(r.zoom, closeTo(2560 / 1920 * 1.5, 1e-9));
      expect(r.textScale, 1);
    });

    test('手机（<600）沿用只放大文字', () {
      expect(
        UtenDisplayZoom.resolve(windowWidth: 390, fontFactor: 1.5),
        const UtenZoomResolution(zoom: 1, textScale: 1.5),
      );
      expect(
        UtenDisplayZoom.resolve(windowWidth: 390, fontFactor: 0.85),
        const UtenZoomResolution(zoom: 1, textScale: 0.85),
      );
    });

    test('平板：整体缩放不把画布压到 600 以下，剩余倍率给文字', () {
      final r = UtenDisplayZoom.resolve(windowWidth: 768, fontFactor: 1.5);
      expect(r.zoom, closeTo(768 / 600, 1e-9));
      expect(r.textScale, closeTo(1.5 / (768 / 600), 1e-9));
      expect(r.zoom * r.textScale, closeTo(1.5, 1e-9));
      // 1024 宽够 1.5 倍整体缩放（画布 683 ≥ 600）。
      expect(
        UtenDisplayZoom.resolve(windowWidth: 1024, fontFactor: 1.5),
        const UtenZoomResolution(zoom: 1.5, textScale: 1),
      );
    });
  });

  group('UtenDisplayZoomBox', () {
    Future<void> pumpAt(
      WidgetTester tester, {
      required Size window,
      double fontFactor = 1,
      required Widget home,
    }) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => UtenDisplayZoomBox(
            fontFactor: fontFactor,
            child: child ?? const SizedBox.shrink(),
          ),
          home: home,
        ),
      );
      await tester.pump();
    }

    testWidgets('2560 窗口：画布 1920 布局、渲染放大 4/3、点击按窗口坐标命中', (tester) async {
      Size? canvas;
      double? dpr;
      var taps = 0;
      await pumpAt(
        tester,
        window: const Size(2560, 1440),
        home: Builder(
          builder: (context) {
            canvas = MediaQuery.sizeOf(context);
            dpr = MediaQuery.devicePixelRatioOf(context);
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: const ValueKey('box'),
                width: 300,
                height: 120,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                ),
              ),
            );
          },
        ),
      );
      expect(canvas, const Size(1920, 1080));
      expect(dpr, closeTo(2560 / 1920, 1e-9));
      // 画布 300×120 → 窗口 400×160。
      final rect = tester.getRect(find.byKey(const ValueKey('box')));
      expect(rect.width, closeTo(400, 1e-6));
      expect(rect.height, closeTo(160, 1e-6));
      // 窗口坐标 (390, 150) 落在盒内（画布 (292.5, 112.5)）；(410, 150) 在盒外。
      await tester.tapAt(const Offset(390, 150));
      await tester.tapAt(const Offset(410, 150));
      expect(taps, 1);
    });

    testWidgets('字号档 1.5 在 1920 窗口：整体放大、textScaler 不变', (tester) async {
      double? textScale;
      Size? canvas;
      await pumpAt(
        tester,
        window: const Size(1920, 1080),
        fontFactor: 1.5,
        home: Builder(
          builder: (context) {
            canvas = MediaQuery.sizeOf(context);
            textScale = MediaQuery.textScalerOf(context).scale(1);
            // 路由页给的是紧约束，Align 放松后 SizedBox 才是 200×100。
            return const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(key: ValueKey('box'), width: 200, height: 100),
            );
          },
        ),
      );
      expect(canvas, const Size(1280, 720));
      expect(textScale, 1);
      expect(
        tester.getSize(find.byKey(const ValueKey('box'))),
        const Size(200, 100),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('box'))).width,
        closeTo(300, 1e-6),
      );
    });

    testWidgets('手机 390 宽 + 字号档 1.5：不套 Transform，只放大文字', (tester) async {
      double? textScale;
      Size? canvas;
      await pumpAt(
        tester,
        window: const Size(390, 844),
        fontFactor: 1.5,
        home: Builder(
          builder: (context) {
            canvas = MediaQuery.sizeOf(context);
            textScale = MediaQuery.textScalerOf(context).scale(1);
            return const SizedBox.shrink();
          },
        ),
      );
      expect(canvas, const Size(390, 844));
      expect(textScale, 1.5);
      expect(find.byType(Transform), findsNothing);
    });

    testWidgets('1920 窗口标准字号：不套 Transform、MediaQuery 原样', (tester) async {
      Size? canvas;
      await pumpAt(
        tester,
        window: const Size(1920, 1080),
        home: Builder(
          builder: (context) {
            canvas = MediaQuery.sizeOf(context);
            return const SizedBox.shrink();
          },
        ),
      );
      expect(canvas, const Size(1920, 1080));
      expect(find.byType(Transform), findsNothing);
    });
  });
}
