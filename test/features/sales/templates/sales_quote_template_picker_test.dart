import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template_download_button.dart';

void main() {
  const templates = [
    SalesQuoteTemplate(
      id: 'compact',
      name: 'Compact',
      useCount: 5,
      sourceName: 'Customer short quotation.xlsx',
    ),
    SalesQuoteTemplate(id: 'detailed', name: 'Detailed', version: 2),
  ];

  Future<void> pumpPicker(
    WidgetTester tester,
    ValueChanged<UtenExportSelection?> result, {
    Size size = const Size(900, 800),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => TextButton(
            child: const Text('Open'),
            onPressed: () async => result(
              await showDialog<UtenExportSelection>(
                context: context,
                builder: (_) =>
                    const SalesQuoteTemplatePicker(templates: templates),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('chooses one template without selecting hidden alternatives', (
    tester,
  ) async {
    UtenExportSelection? result;
    await pumpPicker(tester, (value) => result = value);
    expect(find.text('Customer short quotation.xlsx'), findsOneWidget);
    await tester.tap(find.text('Download selected'));
    await tester.pumpAndSettle();
    expect(result!.bodyParams['templateIds'], ['compact']);
    expect(result!.extension, 'xlsx');
  });

  testWidgets('multiple selections and all produce a zip', (tester) async {
    UtenExportSelection? result;
    await pumpPicker(tester, (value) => result = value);
    await tester.tap(find.byKey(const ValueKey('quote-template-detailed')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download selected'));
    await tester.pumpAndSettle();
    expect(result!.bodyParams['templateIds'], ['compact', 'detailed']);
    expect(result!.extension, 'zip');
    await pumpPicker(tester, (value) => result = value);
    await tester.tap(find.text('Download all'));
    await tester.pumpAndSettle();
    expect(result!.bodyParams['templateIds'], ['compact', 'detailed']);
    expect(result!.extension, 'zip');
  });

  testWidgets('standard fallback and cancellation at compact width', (
    tester,
  ) async {
    UtenExportSelection? result;
    await pumpPicker(
      tester,
      (value) => result = value,
      size: const Size(390, 780),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Use standard format'));
    await tester.pumpAndSettle();
    expect(result!.bodyParams['templateIds'], isEmpty);
    expect(result!.extension, 'xlsx');
    await pumpPicker(tester, (value) => result = value);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
