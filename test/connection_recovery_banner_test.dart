import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/ui/connection_recovery_banner.dart';

void main() {
  testWidgets('shows one clear 48dp retry action and announces recovery', (
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
    final retry = find.byKey(const ValueKey('connection-recovery-retry'));
    expect(retry, findsOneWidget);
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));

    reachable = true;
    await tester.tap(retry);
    await tester.pump();
    await tester.pump();

    expect(find.text('网络已恢复，可以继续使用'), findsOneWidget);
    expect(controller.state.recoveryEpoch, 1);
  });
}
