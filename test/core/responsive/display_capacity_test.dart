import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/settings/uten_font_scaler.dart';
import 'package:uten_imp/core/responsive/display_capacity.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/shared/providers/font_scale_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  test('所有窗口上限200%、自动100%，系统显示与文字设置不消减应用倍率', () {
    for (final window in [
      const Size(320, 640),
      const Size(390, 844),
      const Size(768, 1024),
      const Size(1280, 672),
      const Size(1536, 816),
      const Size(1920, 1000),
      const Size(2560, 1360),
      const Size(5120, 2780),
    ]) {
      for (final system in [1.0, 1.3, 2.0]) {
        expect(
          UtenDisplayCapacity.maxFontFactor(
            window: window,
            systemTextScale: system,
          ),
          2,
        );
        for (final dpr in [1.0, 1.25, 1.5, 2.0, 3.0]) {
          expect(
            UtenDisplayCapacity.recommendedFontFactor(
              window: window,
              devicePixelRatio: dpr,
              ladder: FontScale.ladder,
              systemTextScale: system,
            ),
            1,
          );
        }
      }
    }
  });

  testWidgets('窗口缩小/放大不降低手动倍率，也不抵消系统显示设置', (tester) async {
    UtenDisplayScale? scale;
    Size? canvas;
    for (final logical in [
      const Size(1536, 816),
      const Size(390, 844),
      const Size(2560, 1440),
    ]) {
      tester.view.physicalSize = logical * 1.5;
      tester.view.devicePixelRatio = 1.5;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => UtenDisplayZoomBox.adaptive(
            fontFactor: 2,
            autoLadder: FontScale.ladder,
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              scale = UtenDisplayScale.maybeOf(context);
              canvas = MediaQuery.sizeOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(scale!.effectiveFontFactor, 2);
      expect(scale!.maxFontFactor, 2);
      expect(scale!.isCapped, isFalse);
      expect(canvas, logical / 2);
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  for (final factor in [0.85, 1.5, 2.0]) {
    testWidgets('手机界面$factor倍显示全部档并可切换，无水平溢出', (tester) async {
      SharedPreferences.setMockInitialValues({
        FontScalePreferences.keyFor('user-a'): FontScale.ofFactor(
          factor,
        )!.persistKey,
      });
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(320, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            fontScaleOwnerProvider.overrideWithValue('user-a'),
          ],
          child: Consumer(
            builder: (context, ref, _) => MaterialApp(
              theme: ThemeData(platform: TargetPlatform.android),
              builder: (context, child) => UtenDisplayZoomBox.adaptive(
                fontFactor: ref.watch(fontScaleProvider).factor,
                autoLadder: FontScale.ladder,
                child: child!,
              ),
              home: const Scaffold(
                body: SingleChildScrollView(child: UtenFontScaler()),
              ),
            ),
          ),
        ),
      );
      for (final level in FontScale.selectable) {
        expect(
          find.text('${level.label} ${(level.factor * 100).round()}%'),
          findsOneWidget,
        );
      }
      expect(find.textContaining('暂按'), findsNothing);
      expect(find.textContaining('隐藏'), findsNothing);
      for (final target in tester.widgetList<InkWell>(find.byType(InkWell))) {
        final finder = find.byWidget(target);
        final box = tester.getRect(finder);
        expect(box.width, greaterThanOrEqualTo(48 - 1e-6));
        expect(box.height, greaterThanOrEqualTo(48 - 1e-6));
        expect(box.left, greaterThanOrEqualTo(0));
        expect(box.right, lessThanOrEqualTo(320));
      }
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('自动（100%）'));
      await tester.tap(find.text('自动（100%）'));
      await tester.pumpAndSettle();
      expect(prefs.getString(FontScalePreferences.keyFor('user-a')), 'auto');
      expect(tester.takeException(), isNull);
    });
  }
}
