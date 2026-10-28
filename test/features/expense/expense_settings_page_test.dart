import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/features/expense/models/expense_settings.dart';
import 'package:uten_imp/features/expense/pages/expense_settings_page.dart';
import 'package:uten_imp/features/expense/providers/expense_settings_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/ai_launcher_page_fixture.dart';

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

  for (final size in const [Size(390, 844), Size(1366, 650), Size(1920, 950)]) {
    testWidgets('compact save clears the actual default AI at $size', (
      tester,
    ) async {
      final fixture = await AiLauncherPageFixture.pump(
        tester,
        page: const ExpenseSettingsPage(),
        route: '/expense/settings',
        size: size,
        overrides: [
          currentPermissionsProvider.overrideWithValue({Perm.expenseSettings}),
          expenseSettingsProvider.overrideWith(
            (ref) async => const ExpenseSettings(
              companyName: '测试公司',
              companyTaxNo: '91310000MA1FL8XX00',
              submissionGuide: '保留合法原始凭证并填写业务用途',
              version: 3,
            ),
          ),
        ],
      );
      try {
        final save = find.widgetWithText(UtenButton, '保存设置');
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        final button = tester.getRect(save);
        final launcher = tester.getRect(
          find.byKey(const ValueKey('ai-chat-launcher')),
        );
        final firstField = tester.getRect(find.byType(TextFormField).first);
        expect(button.left, closeTo(firstField.left, .01));
        expect(button.width, lessThan(firstField.width / 2));
        expect(button.overlaps(launcher), isFalse);
        expect(button.top, greaterThanOrEqualTo(0));
        expect(button.bottom, lessThanOrEqualTo(size.height));
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.widget<UtenButton>(save).type, UtenButtonType.primary);
        expect(
          tester
              .widgetList<TextFormField>(find.byType(TextFormField))
              .every((field) => field.enabled == true),
          isTrue,
        );
        // This is editable policy data and a live business requirement.
        expect(find.text('保留合法原始凭证并填写业务用途'), findsOneWidget);
        const invoicePolicy = '关闭后仍须上传合法原始凭证，并填写无发票情况说明。';
        expect(find.text(invoicePolicy), findsNothing);
        final invoiceHint = find.byWidgetPredicate(
          (widget) =>
              widget is UtenFieldHintIcon && widget.info == invoicePolicy,
        );
        await tester.tap(invoiceHint);
        await tester.pump();
        expect(find.text(invoicePolicy), findsOneWidget);
        Tooltip.dismissAllToolTips();
        await tester.pumpAndSettle();
        const description = '由财务维护公司抬头和凭证要求，员工填单时自动显示。';
        expect(find.text(description), findsNothing);
        final hint = find.byWidgetPredicate(
          (widget) => widget is UtenFieldHintIcon && widget.info == description,
        );
        await tester.tap(hint);
        await tester.pump();
        expect(find.text(description), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.dispose(tester);
      }
    });
  }
}
