// 屏幕容量（UtenDisplayCapacity）与自适应整体缩放（UtenDisplayZoomBox.adaptive）测试。
//
// 1) 上限：画布不小于 1200×620；常见机器(1080p 100%/125%/150%/175%、2K、带鱼屏、5K)
//    各自能用到哪一档；系统文字放大占用同一份预算；手机只放大文字封顶 1.5。
// 2) 推荐(自动档)：系统缩放把工作区压小时收一档，但物理尺寸不低于 100% 基准。
// 3) 容器：自动档按推荐生效；手动档超上限按上限生效并标 isCapped；UtenDisplayScale 发布。
// 4) 大字号时留白不放大(gutter 反向收)、导航收成图标栏。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/settings/uten_font_scaler.dart';
import 'package:uten_imp/core/responsive/display_capacity.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/features/shell/widgets/uten_side_nav_rail.dart';
import 'package:uten_imp/shared/providers/font_scale_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// 列出某窗口下设置页可选的手动档(不含自动)。
List<FontScale> _levelsFor(Size window, {double systemTextScale = 1}) {
  final max = UtenDisplayCapacity.maxFontFactor(
    window: window,
    systemTextScale: systemTextScale,
  );
  return [
    for (final s in FontScale.values)
      if (s.factor <= max + 1e-6) s,
  ];
}

void main() {
  group('UtenDisplayCapacity.maxFontFactor', () {
    test('1080p 100%(窗口 1920×1000)：最大到 特大 150%', () {
      final max = UtenDisplayCapacity.maxFontFactor(
        window: const Size(1920, 1000),
      );
      expect(max, closeTo(1.6, 1e-9));
      expect(_levelsFor(const Size(1920, 1000)).last, FontScale.xxLarge);
    });

    test('1080p 125%(逻辑 1536×816)：最大到 大 115%', () {
      expect(
        UtenDisplayCapacity.maxFontFactor(window: const Size(1536, 816)),
        closeTo(1.28, 1e-9),
      );
      expect(_levelsFor(const Size(1536, 816)).last, FontScale.large);
    });

    test('1080p 150%(逻辑 1280×672)：只剩标准及以下', () {
      expect(_levelsFor(const Size(1280, 672)).last, FontScale.medium);
    });

    test('1080p 175%(逻辑 1097×580)：上限保底 1(标准永远可用)', () {
      expect(
        UtenDisplayCapacity.maxFontFactor(window: const Size(1097, 580)),
        1,
      );
      expect(_levelsFor(const Size(1097, 580)), [
        FontScale.xSmall,
        FontScale.small,
        FontScale.medium,
      ]);
    });

    test('2K 100%：宽屏自动放大之上仍可到 特大 150%(字的绝对尺寸更大)', () {
      expect(
        UtenDisplayCapacity.maxFontFactor(window: const Size(2560, 1360)),
        closeTo(1.6, 1e-9),
      );
    });

    test('带鱼屏 3440×1400：高度先到顶，只到 大 115%', () {
      expect(_levelsFor(const Size(3440, 1400)).last, FontScale.large);
    });

    test('5K 100%(5120×2780)：大屏出现 巨大/极大', () {
      final levels = _levelsFor(const Size(5120, 2780));
      expect(levels, contains(FontScale.huge));
      expect(levels.last, FontScale.giant);
    });

    test('系统文字放大占用同一份预算', () {
      expect(
        UtenDisplayCapacity.maxFontFactor(
          window: const Size(1920, 1000),
          systemTextScale: 1.25,
        ),
        closeTo(1.28, 1e-9),
      );
      // 系统文字缩小不给额外预算。
      expect(
        UtenDisplayCapacity.maxFontFactor(
          window: const Size(1920, 1000),
          systemTextScale: 0.9,
        ),
        closeTo(1.6, 1e-9),
      );
    });

    test('手机：只放大文字，应用档 × 系统文字 ≤ 1.5', () {
      expect(
        UtenDisplayCapacity.maxFontFactor(window: const Size(390, 844)),
        1.5,
      );
      expect(
        UtenDisplayCapacity.maxFontFactor(
          window: const Size(390, 844),
          systemTextScale: 1.3,
        ),
        closeTo(1.5 / 1.3, 1e-9),
      );
      expect(
        UtenDisplayCapacity.maxFontFactor(
          window: const Size(390, 844),
          systemTextScale: 2,
        ),
        1,
      );
    });
  });

  group('UtenDisplayCapacity.recommendedFontFactor', () {
    double rec(Size window, double dpr, {double system = 1}) =>
        UtenDisplayCapacity.recommendedFontFactor(
          window: window,
          devicePixelRatio: dpr,
          ladder: FontScale.ladder,
          systemTextScale: system,
        );

    test('工作区够大：标准', () {
      expect(rec(const Size(1920, 1000), 1), 1);
      expect(rec(const Size(2560, 1360), 1), 1);
      expect(rec(const Size(1440, 820), 2), 1); // MacBook 默认缩放
    });

    test('系统缩放 150% 把工作区压到 1280：收到 小 85%', () {
      expect(rec(const Size(1280, 672), 1.5), 0.85);
    });

    test('系统缩放 175%：收到 更小 75%(物理尺寸仍 131%)', () {
      expect(rec(const Size(1097, 580), 1.75), 0.75);
    });

    test('100% 的小屏(1366×690)：不再往下收，物理尺寸不低于基准', () {
      expect(rec(const Size(1366, 690), 1), 1);
      expect(rec(const Size(1280, 672), 1), 1);
    });

    test('系统文字放大按同一口径收', () {
      expect(rec(const Size(1920, 1000), 1.5, system: 1.5), 0.85);
    });

    test('手机：标准', () {
      expect(rec(const Size(390, 844), 3), 1);
    });
  });

  group('UtenDisplayZoomBox.adaptive', () {
    Future<UtenDisplayScale?> pumpAdaptive(
      WidgetTester tester, {
      required Size logical,
      double dpr = 1,
      double? fontFactor,
    }) async {
      tester.view.physicalSize = logical * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      UtenDisplayScale? scale;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => UtenDisplayZoomBox.adaptive(
            fontFactor: fontFactor,
            autoLadder: FontScale.ladder,
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              scale = UtenDisplayScale.maybeOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return scale;
    }

    testWidgets('自动：150% 缩放的 1080p 笔记本按 85% 整体缩放，画布回到 1506 宽', (tester) async {
      Size? canvas;
      tester.view.physicalSize = const Size(1920, 1008);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => UtenDisplayZoomBox.adaptive(
            fontFactor: null,
            autoLadder: FontScale.ladder,
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              canvas = MediaQuery.sizeOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(canvas!.width, closeTo(1280 / 0.85, 1e-6));
      expect(canvas!.height, closeTo(672 / 0.85, 1e-6));
    });

    testWidgets('手动 150% 在 1920×1080：放得下，原样生效', (tester) async {
      final scale = await pumpAdaptive(
        tester,
        logical: const Size(1920, 1080),
        fontFactor: 1.5,
      );
      expect(scale!.effectiveFontFactor, 1.5);
      expect(scale.fontZoom, 1.5);
      expect(scale.isCapped, isFalse);
    });

    testWidgets('手动 150% 在 1536×816：按上限 128% 生效并标记', (tester) async {
      final scale = await pumpAdaptive(
        tester,
        logical: const Size(1536, 816),
        dpr: 1.25,
        fontFactor: 1.5,
      );
      expect(scale!.maxFontFactor, closeTo(1.28, 1e-9));
      expect(scale.effectiveFontFactor, closeTo(1.28, 1e-9));
      expect(scale.isCapped, isTrue);
      expect(scale.devicePixelRatio, 1.25);
    });

    testWidgets('宽屏自动放大不算进 fontZoom', (tester) async {
      final scale = await pumpAdaptive(
        tester,
        logical: const Size(2560, 1440),
        fontFactor: 1.15,
      );
      expect(scale!.fontZoom, closeTo(1.15, 1e-9));
    });

    testWidgets('手动缩小档不受上限影响', (tester) async {
      final scale = await pumpAdaptive(
        tester,
        logical: const Size(1097, 580),
        fontFactor: 0.75,
      );
      expect(scale!.effectiveFontFactor, 0.75);
      expect(scale.isCapped, isFalse);
    });
  });

  group('FontScaleNotifier', () {
    Future<ProviderContainer> containerWith(Map<String, Object> saved) async {
      SharedPreferences.setMockInitialValues(saved);
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('从未设置：自动', () async {
      final c = await containerWith({});
      expect(c.read(fontScaleProvider).isAuto, isTrue);
    });

    test('老版本存的档位键照常恢复', () async {
      final c = await containerWith({'fontScale': 'xxLarge'});
      expect(c.read(fontScaleProvider).manual, FontScale.xxLarge);
      expect(c.read(fontScaleProvider).factor, 1.5);
    });

    test('切回自动持久化为 auto', () async {
      final c = await containerWith({'fontScale': 'large'});
      await c
          .read(fontScaleProvider.notifier)
          .set(const FontScaleChoice.auto());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fontScale'), 'auto');
      expect(c.read(fontScaleProvider).isAuto, isTrue);
    });
  });

  group('大字号的展示方式', () {
    test('页面 gutter：字放大、留白不放大(最小 12)', () {
      expect(UtenContentContainer.gutterForWidth(1280), 32);
      expect(UtenContentContainer.gutterForWidth(1280, fontZoom: 1.5), 21);
      expect(UtenContentContainer.gutterForWidth(700, fontZoom: 1.3), 18);
      expect(UtenContentContainer.gutterForWidth(700, fontZoom: 2), 12);
      // 缩小档不放大留白。
      expect(UtenContentContainer.gutterForWidth(1280, fontZoom: 0.85), 32);
    });

    test('导航栏：1920 窗口标准/大展开，超大起收成图标栏', () {
      bool extended(double factor) => UtenSideNavRail.extendedFor(
        canvasWidth: 1920 / factor,
        fontZoom: factor,
      );
      expect(extended(1), isTrue);
      expect(extended(1.15), isTrue);
      expect(extended(1.3), isFalse);
      expect(extended(1.5), isFalse);
      // 2K 宽屏自动放大不影响(画布 1920)。
      expect(
        UtenSideNavRail.extendedFor(canvasWidth: 1920, fontZoom: 1),
        isTrue,
      );
    });
  });

  group('UtenFontScaler', () {
    testWidgets('1536×816 窗口只列出放得下的档，超上限的手动档仍选中并提示', (tester) async {
      SharedPreferences.setMockInitialValues({'fontScale': 'xxLarge'});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1920, 1020);
      tester.view.devicePixelRatio = 1.25;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: Consumer(
            builder: (context, ref, _) => MaterialApp(
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

      expect(find.text('自动（100%）'), findsOneWidget);
      expect(find.text('大 115%'), findsOneWidget);
      expect(find.text('超大 130%'), findsNothing);
      // 已选的特大保留在列表里，并提示按上限生效。
      expect(find.text('特大 150%'), findsOneWidget);
      expect(find.textContaining('暂按 128% 显示'), findsOneWidget);
      expect(find.textContaining('最大可用「大 115%」'), findsOneWidget);

      await tester.tap(find.text('自动（100%）'));
      await tester.pumpAndSettle();
      expect(prefs.getString('fontScale'), 'auto');
      expect(find.text('特大 150%'), findsNothing);
      expect(find.textContaining('暂按'), findsNothing);
    });
  });
}
