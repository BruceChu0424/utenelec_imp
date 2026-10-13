import 'dart:ui' show DisplayFeature, DisplayFeatureType, DisplayFeatureState;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/responsive/scale.dart';

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double fontSize) =>
      fontSize <= 20 ? fontSize * 2 : fontSize * 1.4;
  @override
  double get textScaleFactor => 2;
}

void main() {
  test('所有窗口/档位只整体缩放，标准不再按宽屏自动放大', () {
    for (final width in [320.0, 390.0, 768.0, 1280.0, 1920.0, 2560.0, 5120.0]) {
      expect(UtenDisplayZoom.autoZoomForWidth(width), 1);
      for (final factor in [0.75, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]) {
        expect(
          UtenDisplayZoom.resolve(windowWidth: width, fontFactor: factor),
          UtenZoomResolution(zoom: factor, textScale: 1),
        );
      }
    }
  });

  Future<void> pumpAt(
    WidgetTester tester, {
    required Size window,
    double factor = 1,
    TextScaler scaler = TextScaler.noScaling,
    MediaQueryData Function(MediaQueryData)? customize,
    required Widget child,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, routed) {
          var media = MediaQuery.of(context).copyWith(textScaler: scaler);
          if (customize != null) media = customize(media);
          return MediaQuery(
            data: media,
            child: UtenDisplayZoomBox(fontFactor: factor, child: routed!),
          );
        },
        home: child,
      ),
    );
    await tester.pump();
  }

  for (final width in [320.0, 390.0, 768.0, 2560.0]) {
    for (final factor in [0.85, 1.0, 1.5, 2.0]) {
      testWidgets('$width 宽/$factor 倍：卡片和图标一起变大，命中按窗口坐标', (tester) async {
        MediaQueryData? canvas;
        var taps = 0;
        await pumpAt(
          tester,
          window: Size(width, 844),
          factor: factor,
          child: Builder(
            builder: (context) {
              canvas = MediaQuery.of(context);
              return Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox(
                    key: ValueKey('card'),
                    width: 80,
                    height: 50,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Icon(Icons.home, key: ValueKey('icon'), size: 24),
                    ),
                  ),
                ),
              );
            },
          ),
        );
        expect(canvas!.size.width, closeTo(width / factor, 1e-6));
        expect(canvas!.size.height, closeTo(844 / factor, 1e-6));
        expect(canvas!.devicePixelRatio, factor);
        expect(canvas!.textScaler, same(TextScaler.noScaling));
        expect(
          tester.getRect(find.byKey(const ValueKey('card'))).size,
          Size(80 * factor, 50 * factor),
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('icon'))).width,
          closeTo(24 * factor, 1e-6),
        );
        await tester.tapAt(Offset(79 * factor, 49 * factor));
        await tester.tapAt(Offset(81 * factor, 49 * factor));
        expect(taps, 1);
      });
    }
  }

  testWidgets('非线性系统字号在手机整体放大后原样继承，辅助图标读正文倍率', (tester) async {
    TextScaler? inherited;
    double? icon;
    await pumpAt(
      tester,
      window: const Size(390, 844),
      factor: 1.5,
      scaler: const _NonlinearScaler(),
      child: Builder(
        builder: (context) {
          inherited = MediaQuery.textScalerOf(context);
          icon = context.scaled(24);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(inherited, same(const _NonlinearScaler()));
    expect(inherited!.scale(14), 28);
    expect(inherited!.scale(32), closeTo(44.8, 1e-6));
    expect(icon, 48);
  });

  testWidgets('安全区/键盘/系统手势/折叠屏换成画布坐标且保留特征状态', (tester) async {
    MediaQueryData? canvas;
    await pumpAt(
      tester,
      window: const Size(390, 844),
      factor: 2,
      customize: (data) => data.copyWith(
        padding: const EdgeInsets.fromLTRB(20, 40, 12, 16),
        viewPadding: const EdgeInsets.fromLTRB(20, 40, 12, 30),
        viewInsets: const EdgeInsets.only(bottom: 240),
        systemGestureInsets: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
        displayFeatures: const [
          DisplayFeature(
            bounds: Rect.fromLTWH(190, 0, 10, 844),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureHalfOpened,
          ),
        ],
      ),
      child: Builder(
        builder: (context) {
          canvas = MediaQuery.of(context);
          return const SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(key: ValueKey('safe'), width: 20, height: 20),
            ),
          );
        },
      ),
    );
    expect(canvas!.padding, const EdgeInsets.fromLTRB(10, 20, 6, 8));
    expect(canvas!.viewPadding, const EdgeInsets.fromLTRB(10, 20, 6, 15));
    expect(canvas!.viewInsets.bottom, 120);
    expect(
      canvas!.systemGestureInsets,
      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    );
    expect(
      canvas!.displayFeatures.single.bounds,
      const Rect.fromLTWH(95, 0, 5, 422),
    );
    expect(canvas!.displayFeatures.single.type, DisplayFeatureType.hinge);
    expect(
      canvas!.displayFeatures.single.state,
      DisplayFeatureState.postureHalfOpened,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('safe'))).topLeft,
      const Offset(20, 40),
    );
  });

  testWidgets('手机放大后 Scaffold 仍正确避让键盘，底部内容可见', (tester) async {
    await pumpAt(
      tester,
      window: const Size(390, 844),
      factor: 1.5,
      customize: (data) =>
          data.copyWith(viewInsets: const EdgeInsets.only(bottom: 240)),
      child: const Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(key: ValueKey('input'), width: 80, height: 40),
        ),
      ),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('input'))).bottom,
      closeTo(604, 1e-6),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机200%浮层仍在窗口内并能选择', (tester) async {
    String? selected;
    await pumpAt(
      tester,
      window: const Size(390, 844),
      factor: 2,
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: PopupMenuButton<String>(
            key: const ValueKey('menu'),
            onSelected: (value) => selected = value,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'chosen', child: Text('选择项')),
            ],
            child: const SizedBox(width: 60, height: 40, child: Text('打开')),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('menu')));
    await tester.pumpAndSettle();
    final bounds = tester.getRect(find.text('选择项'));
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(390));
    await tester.tap(find.text('选择项'));
    await tester.pumpAndSettle();
    expect(selected, 'chosen');
    expect(tester.takeException(), isNull);
  });
}
