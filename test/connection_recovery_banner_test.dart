import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/ui/connection_recovery_banner.dart';
import 'package:uten_imp/core/ui/uten_top_banner_card.dart';

void main() {
  testWidgets('shows one compact retry action and announces recovery', (
    tester,
  ) async {
    var reachable = false;
    final controller = ConnectionRecoveryController(
      probe: () async => reachable,
      probeDelays: const [Duration(hours: 1)],
      restoredDisplayDuration: const Duration(hours: 1),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionRecoveryProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          supportedLocales: [Locale('zh'), Locale('en')],
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(body: Align(child: ConnectionRecoveryBanner())),
        ),
      ),
    );

    controller.markDisconnected();
    await tester.pump();

    expect(find.text('暂时连不上服务器，系统会继续自动连接'), findsOneWidget);
    expect(find.text('运行与灾备'), findsOneWidget);
    final retry = find.byKey(const ValueKey('connection-recovery-retry'));
    expect(retry, findsOneWidget);
    // 视觉 40dp 紧凑按钮；OutlinedButton 默认 MaterialTapTargetSize.padded
    // 保证命中区仍为 48dp。
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(40));

    reachable = true;
    await tester.tap(retry);
    await tester.pump();
    await tester.pump();

    expect(find.text('网络已恢复，可以继续使用'), findsOneWidget);
    expect(controller.state.recoveryEpoch, 1);
  });

  testWidgets(
    'connection bar docks in-flow above the floating notice card',
    (tester) async {
      final controller = ConnectionRecoveryController(
        probe: () async => true,
        probeDelays: const <Duration>[],
      )..markRetrying(1);
      final container = ProviderContainer(
        overrides: [
          connectionRecoveryProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('zh'),
            supportedLocales: [Locale('zh'), Locale('en')],
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConnectionRecoveryBanner(useSafeArea: false),
                  AppNotificationHost(useSafeArea: false),
                ],
              ),
            ),
          ),
        ),
      );
      container
          .read(appNotificationProvider.notifier)
          .showInfo('新的采购任务', duration: const Duration(hours: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final bar = tester.getRect(find.byType(ConnectionRecoveryBanner));
      // 连接横幅不再走 UtenTopBannerCard（占顶下推通栏）；悬浮卡片只剩通知弹条。
      final cards = find.byType(UtenTopBannerCard);
      expect(cards, findsOneWidget);
      final noticeRect = tester.getRect(cards.at(0));
      expect(noticeRect.top, greaterThanOrEqualTo(bar.bottom));
    },
  );
}
