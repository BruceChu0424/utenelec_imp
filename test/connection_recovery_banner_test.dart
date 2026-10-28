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

void _expectCenteredStatus(
  WidgetTester tester,
  AppLocalizations l10n,
  String message,
) {
  final banner = find.byType(ConnectionRecoveryBanner);
  final group = find.byKey(const ValueKey('connection-recovery-message-group'));
  final text = find.byKey(const ValueKey('connection-recovery-message'));
  expect(find.text(message), findsOneWidget);
  expect(tester.widget<Text>(text).textAlign, TextAlign.center);
  final bounds = tester.getRect(banner);
  final groupBounds = tester.getRect(group);
  expect(
    bounds.height,
    lessThanOrEqualTo(
      tester.view.physicalSize.height / tester.view.devicePixelRatio,
    ),
  );
  expect(groupBounds.center.dx, closeTo(bounds.center.dx, 0.5));
  expect(groupBounds.left, greaterThanOrEqualTo(bounds.left));
  expect(groupBounds.right, lessThanOrEqualTo(bounds.right));
  expect(find.byKey(const ValueKey('connection-recovery-retry')), findsNothing);
  expect(find.text(l10n.connectionRetryNow), findsNothing);
  expect(
    find.descendant(
      of: banner,
      matching: find.byWidgetPredicate(
        (widget) => widget is ButtonStyleButton || widget is IconButton,
      ),
    ),
    findsNothing,
  );
  expect(tester.takeException(), isNull);
}

void main() {
  for (final locale in const [Locale('zh'), Locale('en'), Locale('ko')]) {
    testWidgets(
      '${locale.languageCode}: centers status without a retry button and recovers automatically',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final displayZoom = ValueNotifier(1.0);
        addTearDown(displayZoom.dispose);
        var reachable = false;
        var probes = 0;
        final controller = ConnectionRecoveryController(
          probe: () async {
            probes++;
            return reachable;
          },
          probeDelays: const [Duration(seconds: 1)],
          probeDelayJitter: (delay) => delay,
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

        final l10n = AppLocalizations.of(
          tester.element(find.byType(ConnectionRecoveryBanner)),
        );
        controller.markRetrying(1);
        await tester.pump();
        _expectCenteredStatus(tester, l10n, l10n.connectionReconnecting);

        controller.markDisconnected();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        _expectCenteredStatus(tester, l10n, l10n.connectionDisconnected);
        expect(find.text('运行与灾备'), findsNothing);

        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final width in [800.0, 320.0]) {
          tester.view.physicalSize = Size(width, 540);
          await tester.pump();
          _expectCenteredStatus(tester, l10n, l10n.connectionDisconnected);
        }

        tester.platformDispatcher.textScaleFactorTestValue = 1;
        displayZoom.value = 2;
        for (final width in [800.0, 460.0, 320.0]) {
          tester.view.physicalSize = Size(width, 720);
          await tester.pump();
          _expectCenteredStatus(tester, l10n, l10n.connectionDisconnected);
          expect(
            tester.getSize(find.byType(ConnectionRecoveryBanner)).height,
            lessThan(360),
            reason: 'The notice leaves room for the login form at 200% zoom.',
          );
        }

        expect(probes, 0, reason: 'Layout changes do not start extra probes.');
        reachable = true;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        _expectCenteredStatus(tester, l10n, l10n.connectionRestored);
        expect(
          probes,
          1,
          reason: 'The existing timer reconnects automatically.',
        );
        expect(controller.state.recoveryEpoch, 1);
        await tester.pump(const Duration(seconds: 3));
        expect(
          find.byKey(const ValueKey('connection-recovery-message-group')),
          findsNothing,
        );
        expect(controller.state.phase, ConnectionRecoveryPhase.connected);
        await tester.pump(const Duration(seconds: 30));
        expect(probes, 1, reason: 'Recovery cancels background probes.');
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
