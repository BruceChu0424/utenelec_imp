import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/production/models/material_analysis_bom_diagnostic.dart';
import 'package:uten_imp/features/production/widgets/material_analysis_bom_issues_panel.dart';

void main() {
  for (final size in [const Size(420, 700), const Size(1200, 800)]) {
    testWidgets('all findings can be selected and forwarded at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Set<String>? forwarded;
      var continued = false;
      final diagnostic = MaterialAnalysisBomDiagnostic(
        findings: [
          for (var index = 0; index < 30; index++)
            MaterialAnalysisBomFinding(
              key: 'issue-$index',
              rootLabel: '产品$index',
              parentLabel: '半成品',
              componentLabel: '组件$index',
              reason: '组件没有基本单位',
              fix: '维护基本单位',
            ),
        ],
        blockedSourceIndexes: {0},
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MaterialAnalysisBomIssuesPanel(
              diagnostic: diagnostic,
              sourceCount: 2,
              busy: false,
              onRecheck: () async {},
              onForward: (keys) async {
                forwarded = keys;
              },
              onContinue: () {
                continued = true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('全选问题'));
      await tester.pump();
      final forward = find.byKey(const Key('bom-issues-forward'));
      await tester.ensureVisible(forward);
      await tester.tap(forward);
      await tester.pump();
      expect(forwarded, {
        for (var index = 0; index < 30; index++) 'issue-$index',
      });
      final continueButton = find.byKey(const Key('bom-issues-continue'));
      await tester.ensureVisible(continueButton);
      await tester.tap(continueButton);
      expect(continued, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'read-only inspection hides forwarding and a blocked-only batch cannot continue',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MaterialAnalysisBomIssuesPanel(
              diagnostic: const MaterialAnalysisBomDiagnostic(
                findings: [],
                blockedSourceIndexes: {0},
              ),
              sourceCount: 1,
              busy: false,
              onRecheck: () async {},
              onForward: null,
              onContinue: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('bom-issues-forward')), findsNothing);
      expect(find.byKey(const Key('bom-issues-continue')), findsNothing);
    },
  );
}
