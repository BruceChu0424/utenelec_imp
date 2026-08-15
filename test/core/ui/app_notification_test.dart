import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/ui/uten_top_banner_card.dart';

void main() {
  testWidgets('top notification becomes visible and exposes a live region', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Stack(
            children: [
              Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => context.appError('排产预览已过期'),
                    child: const Text('触发错误'),
                  ),
                ),
              ),
              const Align(
                alignment: Alignment.topCenter,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('触发错误'));
    await tester.pump();
    expect(find.text('排产预览已过期'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 110));
    final fade = tester.widget<FadeTransition>(
      find.byWidgetPredicate(
        (widget) =>
            widget is FadeTransition &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'app-notification-fade-',
            ),
      ),
    );
    expect(fade.opacity.value, greaterThan(0));

    final hasLiveRegion = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .any((semantics) => semantics.properties.liveRegion == true);
    expect(hasLiveRegion, isTrue);
    expect(find.byTooltip('关闭通知'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭通知'));
    await tester.pumpAndSettle();
    expect(find.text('排产预览已过期'), findsNothing);
  });

  // 回归：顶部弹条只占卡片宽度，卡片两侧的空白必须把点击放行给下方页面
  // （历史 bug：卡片被包在会撑满整行宽的 Center + Dismissible 里，整行吞点击）。
  testWidgets(
    'banner shrinks to the card and lets taps beside it pass through',
    (tester) async {
      var behindTaps = 0;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Stack(
              children: [
                // 底层：全宽点击计数器。能收到点击 = 通知层没拦住两侧。
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => behindTaps++,
                    child: const ColoredBox(color: Color(0x00000000)),
                  ),
                ),
                // 通知层：与真实 app 一致，Positioned 顶栏全宽。
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AppNotificationHost(),
                ),
                // 触发按钮放在底部，避免与顶部通知行重叠。
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Builder(
                    builder: (context) => ElevatedButton(
                      onPressed: () => context.appInfo('一条顶部通知，用于验证两侧点击穿透'),
                      child: const Text('触发通知'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('触发通知'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160)); // 等滑入动画结束

      // 卡片宽度 ≤ 720，且远小于屏幕宽度——不是整行。
      final cardRect = tester.getRect(find.byType(UtenTopBannerCard));
      expect(cardRect.width, lessThanOrEqualTo(720));

      // 卡片左侧空白的中点（一定在卡片之外、又在通知行高度内）点击，应穿透到底层。
      final beside = Offset(cardRect.left / 2, cardRect.center.dy);
      await tester.tapAt(beside);
      await tester.pump();
      expect(behindTaps, greaterThan(0));
    },
  );

  // 回归：顶部弹条必须按内容收缩，而不是恒为 720 上限。
  // 历史 bug：UtenTopBannerCard 内部 Row 用默认 mainAxisSize.max + Expanded(content)，
  // 导致每条弹条都顶满 720 宽——短文案在窄窗下近乎屏宽，加上 hover 时 InkWell 把整张
  // 卡涂一层前景色 8%，用户误以为「鼠标移进去突然变成整屏灰色面板」。修复：Row 改
  // mainAxisSize.min + Expanded→Flexible，让短文案收缩成小卡，长文案仍 ≤720 换行。
  testWidgets('banner shrinks to content width for short messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Color(0x00000000)),
              ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () => context.appInfo('已保存'),
                    child: const Text('触发'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('触发'));
    await tester.pump();
    await tester.pumpAndSettle();

    final cardRect = tester.getRect(find.byType(UtenTopBannerCard));
    // 短文案「已保存」应远小于 720 上限（实际约 150-250）——证明按内容收缩，而非顶满。
    expect(cardRect.width, lessThan(400));
    expect(cardRect.width, lessThanOrEqualTo(720));
  });

  // 回归：长文案仍能在 720 上限处换行，不溢出、不被裁切。
  testWidgets('banner wraps long messages within maxWidth without overflow', (
    tester,
  ) async {
    final flutterErrors = <FlutterErrorDetails>[];
    FlutterError.onError = flutterErrors.add;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Color(0x00000000)),
              ),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppNotificationHost(),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () => context.appInfo(
                      '这是一条很长的通知消息，用于验证内容收缩后长文本仍能在最大宽度处正常换行，'
                      '既不会超出卡片上限导致 RenderFlex 溢出异常，也不会被圆角裁切丢字。',
                    ),
                    child: const Text('触发'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('触发'));
    await tester.pump();
    await tester.pumpAndSettle();

    final cardRect = tester.getRect(find.byType(UtenTopBannerCard));
    expect(cardRect.width, lessThanOrEqualTo(720));
    expect(flutterErrors, isEmpty, reason: '长文案换行不应触发 RenderFlex 溢出等布局异常');
  });
}
