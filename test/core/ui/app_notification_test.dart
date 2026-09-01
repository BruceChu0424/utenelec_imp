import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/ui/uten_notify.dart';
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
    final closeSize = tester.getSize(find.byTooltip('关闭通知'));
    expect(closeSize.width, greaterThanOrEqualTo(48));
    expect(closeSize.height, greaterThanOrEqualTo(48));

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
    final previousErrorHandler = FlutterError.onError;
    final flutterErrors = <FlutterErrorDetails>[];
    FlutterError.onError = flutterErrors.add;
    addTearDown(() => FlutterError.onError = previousErrorHandler);

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

  testWidgets('notifications stack newest first, expand, and keep overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Align(
            alignment: Alignment.topCenter,
            child: AppNotificationHost(),
          ),
        ),
      ),
    );

    final notifications = container.read(appNotificationProvider.notifier);
    final dismissed = <int>[];
    for (var index = 1; index <= 4; index++) {
      notifications.showMessage(
        '通知 $index',
        duration: const Duration(hours: 1),
        onDismissed: () => dismissed.add(index),
        force: true,
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(container.read(appNotificationProvider), hasLength(4));
    expect(find.byType(UtenTopBannerCard), findsOneWidget);
    expect(find.text('通知 4'), findsOneWidget);
    expect(find.text('通知 1'), findsNothing);
    expect(find.text('展开最近 3 条通知，共 4 条'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('app-notification-stack-toggle')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(UtenTopBannerCard), findsNWidgets(3));
    expect(find.text('通知 4'), findsOneWidget);
    expect(find.text('通知 3'), findsOneWidget);
    expect(find.text('通知 2'), findsOneWidget);
    expect(find.text('通知 1'), findsNothing);
    expect(dismissed, isEmpty);

    final newestCard = find.ancestor(
      of: find.text('通知 4'),
      matching: find.byType(UtenTopBannerCard),
    );
    await tester.tap(
      find.descendant(
        of: newestCard,
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();

    expect(dismissed, <int>[4]);
    expect(container.read(appNotificationProvider), hasLength(3));
    expect(find.byType(UtenTopBannerCard), findsNWidgets(3));
    expect(find.text('通知 1'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('app-notification-stack-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenTopBannerCard), findsOneWidget);
    expect(find.text('通知 3'), findsOneWidget);

    for (final expected in <int>[3, 2, 1]) {
      expect(find.text('通知 $expected'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭通知'));
      await tester.pumpAndSettle();
    }
    expect(container.read(appNotificationProvider), isEmpty);
    expect(find.byType(UtenTopBannerCard), findsNothing);
    expect(dismissed, <int>[4, 3, 2, 1]);
    await tester.pump(const Duration(seconds: 1));
    expect(dismissed, <int>[4, 3, 2, 1]);
  });

  testWidgets(
    'system disableAnimations makes banner enter and exit immediately',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: Align(
                alignment: Alignment.topCenter,
                child: AppNotificationHost(),
              ),
            ),
          ),
        ),
      );

      container
          .read(appNotificationProvider.notifier)
          .showInfo('减弱动效通知', duration: const Duration(hours: 1));
      await tester.pump();

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
      expect(fade.opacity.value, 1);

      await tester.tap(find.byTooltip('关闭通知'));
      await tester.pump();
      expect(find.text('减弱动效通知'), findsNothing);
    },
  );

  testWidgets('auto-dismiss timer pauses while app is in background', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var dismissals = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Align(
            alignment: Alignment.topCenter,
            child: AppNotificationHost(),
          ),
        ),
      ),
    );

    container
        .read(appNotificationProvider.notifier)
        .showMessage(
          '后台仍需阅读',
          duration: const Duration(milliseconds: 200),
          onDismissed: () => dismissals++,
        );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('后台仍需阅读'), findsOneWidget);
    expect(dismissals, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text('后台仍需阅读'), findsNothing);
    expect(dismissals, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(dismissals, 1);
  });

  testWidgets('small screen with large text shows one bounded banner', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final previousErrorHandler = FlutterError.onError;
    final flutterErrors = <FlutterErrorDetails>[];
    FlutterError.onError = flutterErrors.add;
    addTearDown(() => FlutterError.onError = previousErrorHandler);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(3),
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: AppNotificationHost(),
            ),
          ),
        ),
      ),
    );

    final notifications = container.read(appNotificationProvider.notifier);
    for (var index = 0; index < 3; index++) {
      notifications.showMessage(
        '这是一条很长的业务通知正文，用于验证大字号手机顶部条不会越过视口或产生布局溢出。',
        title: '重要采购任务需要及时处理并打开对应申请详情',
        onTap: () {},
        duration: const Duration(hours: 1),
        force: true,
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(UtenTopBannerCard), findsOneWidget);
    expect(container.read(appNotificationProvider), hasLength(3));
    expect(flutterErrors, isEmpty);
  });

  testWidgets('business banner action runs only once during dismissal', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var opens = 0;
    var dismissals = 0;
    late BuildContext bannerContext;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Stack(
            children: [
              Builder(
                builder: (context) {
                  bannerContext = context;
                  return const SizedBox.shrink();
                },
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
    UtenNotify.banner(
      bannerContext,
      message: '点击查看采购申请',
      duration: const Duration(hours: 1),
      onTap: () => opens++,
      onDismissed: () => dismissals++,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('点击查看采购申请'));
    await tester.tap(find.text('点击查看采购申请'));
    expect(opens, 1);
    expect(dismissals, 0);
    await tester.pumpAndSettle();
    expect(find.text('点击查看采购申请'), findsNothing);
    expect(dismissals, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(opens, 1);
    expect(dismissals, 1);
  });

  testWidgets(
    'long actionable banner discloses full text without running its action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var opens = 0;
      const message =
          '这是一条需要跳转处理的超长业务通知，用于确认正文被截断时仍可在原位置查看完整内容，'
          '并且点击问号只展开说明，不会误触通知本身的跳转动作。'
          '请核对对应单据、责任人、处理期限和失败后的恢复方式，再继续下一步操作。';
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Align(
              alignment: Alignment.topCenter,
              child: AppNotificationHost(),
            ),
          ),
        ),
      );

      container
          .read(appNotificationProvider.notifier)
          .showMessage(
            message,
            duration: const Duration(hours: 1),
            onTap: () => opens++,
            force: true,
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final help = find.byIcon(Icons.help_outline_rounded);
      expect(help, findsOneWidget);
      final helpButton = find.ancestor(
        of: help,
        matching: find.byType(IconButton),
      );
      final helpSize = tester.getSize(helpButton);
      expect(helpSize.width, greaterThanOrEqualTo(44));
      expect(helpSize.height, greaterThanOrEqualTo(44));

      await tester.tap(help);
      await tester.pump();

      expect(opens, 0);
      expect(find.byType(UtenTopBannerCard), findsOneWidget);
      expect(find.text(message), findsNWidgets(2));
    },
  );

  testWidgets('swipe dismissal invokes onDismissed exactly once', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var dismissals = 0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Align(
            alignment: Alignment.topCenter,
            child: AppNotificationHost(),
          ),
        ),
      ),
    );

    container
        .read(appNotificationProvider.notifier)
        .showMessage(
          '滑动关闭通知',
          duration: const Duration(hours: 1),
          onDismissed: () => dismissals++,
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.fling(find.text('滑动关闭通知'), const Offset(500, 0), 1200);
    await tester.pumpAndSettle();

    expect(find.text('滑动关闭通知'), findsNothing);
    expect(container.read(appNotificationProvider), isEmpty);
    expect(dismissals, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(dismissals, 1);
  });

  testWidgets('clear and host disposal never invoke onDismissed', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final dismissed = <String>[];

    Widget host() => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Align(
          alignment: Alignment.topCenter,
          child: AppNotificationHost(),
        ),
      ),
    );

    await tester.pumpWidget(host());
    final notifications = container.read(appNotificationProvider.notifier);
    notifications.showMessage(
      '可见后被 clear',
      duration: const Duration(hours: 1),
      onDismissed: () => dismissed.add('visible-clear'),
    );
    notifications.showMessage(
      '排队中被 clear',
      duration: const Duration(hours: 1),
      onDismissed: () => dismissed.add('queued-clear'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('可见后被 clear'), findsNothing);
    expect(find.text('排队中被 clear'), findsOneWidget);

    notifications.clear();
    await tester.pump();
    expect(dismissed, isEmpty);

    notifications.showMessage(
      '宿主销毁时可见',
      duration: const Duration(hours: 1),
      onDismissed: () => dismissed.add('visible-dispose'),
    );
    notifications.showMessage(
      '宿主销毁时排队',
      duration: const Duration(hours: 1),
      onDismissed: () => dismissed.add('queued-dispose'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    expect(dismissed, isEmpty);
    notifications.clear();
    expect(dismissed, isEmpty);
  });
}
