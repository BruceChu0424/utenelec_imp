import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/quality/widgets/inspection_report_confirm_dialog.dart';

void main() {
  for (final systemFactor in [1.0, 2.0]) {
    testWidgets('inspection quantities and reason survive 200%/$systemFactor', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? result;
      final draftReasons = <String>[];
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            sessionProvider.overrideWith(_Session.new),
          ],
          child: MaterialApp(
            theme: buildLightTheme().copyWith(platform: TargetPlatform.android),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(systemFactor)),
              child: UtenDisplayZoomBox(
                fontFactor: 2,
                child: UtenControlTheme(child: child!),
              ),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () async {
                      result = await showInspectionReportConfirmDialog(
                        context,
                        lineCount: 1,
                        passTotalText: '123456789.123',
                        failTotalText: '9876543.21',
                        lines: const [
                          InspectionReportConfirmLine(
                            label: '需要完整核对的长货品名称及来源',
                            passText: '123456789.123',
                            failText: '9876543.21',
                            dim: '个',
                          ),
                        ],
                        onReasonChanged: draftReasons.add,
                      );
                    },
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final submit = find.byKey(const Key('inspection-report-confirm-submit'));
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.ensureVisible(find.byType(TextField));
      await tester.pumpAndSettle();
      final errorHint = find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldHintIcon && widget.errorMessage == '结论原因必填',
      );
      expect(errorHint, findsOneWidget);
      await tester.ensureVisible(errorHint);
      await tester.pumpAndSettle();
      await tester.tap(errorHint);
      await tester.pumpAndSettle();
      expect(find.textContaining('结论原因必填'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '原始检验结论原因');
      await tester.pumpAndSettle();
      expect(draftReasons.last, '原始检验结论原因');
      for (final text in [
        '需要完整核对的长货品名称及来源',
        '合格 123456789.123 个',
        '不合格 9876543.21 个',
      ]) {
        await tester.ensureVisible(find.text(text));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(text), findsOneWidget);
      }
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(result, '原始检验结论原因');
      expect(
        find.byKey(const Key('inspection-report-confirm-submit')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}
