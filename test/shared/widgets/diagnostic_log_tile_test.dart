import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/widgets/diagnostic_log_tile.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    theme: buildLightTheme(),
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
  testWidgets(
    'one tap exports .log and an in-flight export cannot be duplicated',
    (tester) async {
      final gate = Completer<String>();
      var calls = 0;
      await tester.pumpWidget(
        host(
          DiagnosticLogTile(
            exportLog: () {
              calls++;
              return gate.future;
            },
          ),
        ),
      );
      await tester.tap(find.text('运行日志'));
      await tester.pump();
      await tester.tap(find.text('运行日志'));
      await tester.pump();
      expect(calls, 1);
      gate.complete('fixture/UTEN.log');
      await tester.pumpAndSettle();
      expect(find.textContaining('UTEN.log'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow large-text settings still expose export without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(375, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: DiagnosticLogTile(exportLog: () async => 'fixture/UTEN.log'),
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('导出 .log'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'finishing after the settings surface retires does not touch its state',
    (tester) async {
      final gate = Completer<String>();
      await tester.pumpWidget(
        host(DiagnosticLogTile(exportLog: () => gate.future)),
      );
      await tester.tap(find.text('运行日志'));
      await tester.pumpWidget(host(const SizedBox()));
      gate.complete('fixture/UTEN.log');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
