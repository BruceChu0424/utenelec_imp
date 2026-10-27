import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/ui/connection_recovery_banner.dart';
import 'package:uten_imp/core/ui/uten_top_banner_card.dart';

void main() {
  for (final locale in const [Locale('zh'), Locale('en'), Locale('ko')]) {
    testWidgets(
      '${locale.languageCode}: shows an inline retry action and announces recovery',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final displayZoom = ValueNotifier(1.0);
        addTearDown(displayZoom.dispose);
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
            child: MaterialApp(
              locale: locale,
              supportedLocales: const [
                Locale('zh'),
                Locale('en'),
                Locale('ko'),
              ],
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: ValueListenableBuilder<double>(
                valueListenable: displayZoom,
                builder: (context, zoom, child) =>
                    UtenDisplayZoomBox(fontFactor: zoom, child: child!),
                child: const Scaffold(
                  body: Align(child: ConnectionRecoveryBanner()),
                ),
              ),
            ),
          ),
        );

        controller.markDisconnected();
        await tester.pump();

        final l10n = AppLocalizations.of(
          tester.element(find.byType(ConnectionRecoveryBanner)),
        );
        final message = find.text(l10n.connectionDisconnected);
        expect(message, findsOneWidget);
        expect(find.text('运行与灾备'), findsNothing);
        final retry = find.byKey(const ValueKey('connection-recovery-retry'));
        expect(retry, findsOneWidget);
        expect(
          tester.getRect(retry).left,
          closeTo(tester.getRect(message).right + 8, 0.01),
        );
        // 视觉 40dp 紧凑按钮；OutlinedButton 默认 MaterialTapTargetSize.padded
        // 保证命中区仍为 48dp。
        expect(tester.getSize(retry).height, greaterThanOrEqualTo(40));

        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final width in [800.0, 320.0]) {
          tester.view.physicalSize = Size(width, 540);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(retry.hitTestable(), findsOneWidget);
          expect(tester.getRect(retry).right, lessThanOrEqualTo(width));
        }

        tester.platformDispatcher.textScaleFactorTestValue = 1;
        displayZoom.value = 2;
        for (final width in [800.0, 460.0]) {
          tester.view.physicalSize = Size(width, 720);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(retry.hitTestable(), findsOneWidget);
          expect(tester.getRect(retry).right, lessThanOrEqualTo(width));
          expect(
            tester.getSize(find.byType(ConnectionRecoveryBanner)).height,
            lessThan(360),
            reason: 'The notice leaves room for the login form at 200% zoom.',
          );
        }

        reachable = true;
        await tester.tap(retry);
        await tester.pump();
        await tester.pump();

        expect(find.text(l10n.connectionRestored), findsOneWidget);
        expect(controller.state.recoveryEpoch, 1);
      },
    );
  }

  testWidgets('connection bar docks in-flow above the floating notice card', (
    tester,
  ) async {
    final controller = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const <Duration>[],
    )..markRetrying(1);
    final container = ProviderContainer(
      overrides: [connectionRecoveryProvider.overrideWith((ref) => controller)],
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
  });
}
