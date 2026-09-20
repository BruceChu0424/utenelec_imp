import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/pages/expense_settings_page.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  test(
    'settings route requires its distinct finance configuration permission',
    () {
      expect(requiredAnyPermFor('/expense/settings'), [Perm.expenseSettings]);
      expect(requiredAnyPermFor('/expense/claim-id/edit'), [Perm.expenseApply]);
      expect(
        requiredAnyPermFor('/finance'),
        containsAll([
          Perm.expenseApprove,
          Perm.expensePay,
          Perm.expenseSettings,
        ]),
      );
    },
  );

  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets(
      'settings at $width keeps policy editable only with permission',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue({Perm.expenseApply}),
              expenseSettingsProvider.overrideWith(
                (ref) async => const ExpenseSettings(
                  companyName: '测试公司',
                  companyTaxNo: '91310000MA1FL8XX00',
                  submissionGuide: '保留合法原始凭证并填写业务用途',
                  version: 3,
                ),
              ),
            ],
            child: const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: ExpenseSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('测试公司'), findsOneWidget);
        expect(find.text('保存设置'), findsNothing);
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widgetList<TextFormField>(find.byType(TextFormField))
              .every((field) => field.enabled == false),
          isTrue,
        );
      },
    );
  }
}
