import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Widget _app({required Set<String> permissions, required Widget child}) {
  return ProviderScope(
    overrides: [currentPermissionsProvider.overrideWithValue(permissions)],
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('export button is hidden without its required permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        permissions: const {},
        child: const UtenExportButton(
          endpoint: '/reports/export',
          report: 'detail',
          queryParams: {},
          requiredPermission: Perm.salesReportExport,
        ),
      ),
    );

    expect(find.text('下载表格'), findsNothing);
  });

  testWidgets('export button is visible with its required permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        permissions: const {Perm.salesReportExport},
        child: const UtenExportButton(
          endpoint: '/reports/export',
          report: 'detail',
          queryParams: {},
          requiredPermission: Perm.salesReportExport,
        ),
      ),
    );

    expect(find.text('下载表格'), findsOneWidget);
  });

  testWidgets(
    'export dialog allows plain download and a one-character password',
    (tester) async {
      await tester.pumpWidget(
        _app(
          permissions: const {Perm.salesReportExport},
          child: const UtenExportButton(
            endpoint: '/reports/export',
            report: 'detail',
            queryParams: {},
            requiredPermission: Perm.salesReportExport,
          ),
        ),
      );

      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();

      expect(find.text('打开密码(可选，1–128 位)'), findsOneWidget);
      expect(find.text('直接下载'), findsOneWidget);
      expect(find.text('确认密码'), findsNothing);

      await tester.enterText(find.byType(TextField), '1');
      await tester.pump();

      expect(find.text('确认密码'), findsOneWidget);
      expect(find.text('加密下载'), findsOneWidget);
    },
  );

  testWidgets('print preview applies permission to its nested Excel action', (
    tester,
  ) async {
    Future<UtenPrintTable> loader() async =>
        const UtenPrintTable(headers: ['列'], rows: []);

    await tester.pumpWidget(
      _app(
        permissions: const {},
        child: UtenPrintPreviewButton(
          title: '测试报表',
          loader: loader,
          exportEndpoint: '/reports/export',
          exportPermission: Perm.financeReportExport,
        ),
      ),
    );
    await tester.tap(find.text('预览打印'));
    await tester.pumpAndSettle();

    expect(find.text('下载Excel'), findsNothing);
  });
}
