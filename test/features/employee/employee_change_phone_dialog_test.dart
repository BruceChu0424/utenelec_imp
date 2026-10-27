import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/widgets/employee_contact_edit_dialog.dart';

void main() {
  for (final language in ['zh', 'en', 'ko']) {
    for (final hasAccount in [false, true]) {
      testWidgets('$language 更号确认保留真实账号说明、窄屏大字号及输入校验 $hasAccount', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? result;
        late AppLocalizations l10n;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  l10n = AppLocalizations.of(context);
                  return FilledButton(
                    onPressed: () async {
                      result = await showEmployeeChangePhoneDialog(
                        context,
                        '13900139000',
                        hasAccount: hasAccount,
                      );
                    },
                    child: const Text('open'),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            hasAccount
                ? l10n.employeeChangePhoneAccountNotice
                : l10n.employeeChangePhoneNoAccountNotice,
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text(l10n.employeeChangePhoneConfirm));
        await tester.tap(find.text(l10n.employeeChangePhoneConfirm));
        await tester.pumpAndSettle();
        // Uten fields disclose validation in the in-field hint, rather than
        // reserving a separate line below the input.
        final errorHint = find.byTooltip(
          RegExp(RegExp.escape(l10n.employeeOnboardPhoneInvalid)),
        );
        expect(errorHint, findsOneWidget);
        await tester.ensureVisible(errorHint);
        await tester.tap(errorHint);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(l10n.employeeOnboardPhoneInvalid),
          findsOneWidget,
        );
        expect(result, isNull);
        await tester.ensureVisible(find.byType(TextField));
        await tester.enterText(find.byType(TextField), '13800138000');
        await tester.pumpAndSettle();
        expect(errorHint, findsNothing);
        await tester.ensureVisible(find.text(l10n.employeeChangePhoneConfirm));
        await tester.tap(find.text(l10n.employeeChangePhoneConfirm));
        await tester.pumpAndSettle();
        expect(result, '13800138000');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
