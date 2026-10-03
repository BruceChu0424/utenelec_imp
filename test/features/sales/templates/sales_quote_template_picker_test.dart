import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template_download_button.dart';
import 'package:uten_imp/features/sales/templates/sales_quote_template_learning.dart';

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
    bool canUpload = false,
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
                builder: (_) => SalesQuoteTemplatePicker(
                  templates: templates,
                  canUpload: canUpload,
                ),
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
    expect(result!.bodyParams['templateVersions'], {'compact': 1});
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
    expect(result!.bodyParams['templateVersions'], {
      'compact': 1,
      'detailed': 2,
    });
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

  testWidgets('existing template offers further learning at compact width', (
    tester,
  ) async {
    UtenExportSelection? result;
    await pumpPicker(
      tester,
      (value) => result = value,
      size: const Size(390, 780),
      canUpload: true,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Upload and learn template'));
    await tester.pumpAndSettle();
    expect(result!.bodyParams, {'_uploadTemplate': true});
  });

  testWidgets(
    'missing customer template offers explicit upload and standard fallback',
    (tester) async {
      UtenExportSelection? result;
      await tester.binding.setSurfaceSize(const Size(390, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> open(bool canUpload) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showDialog<UtenExportSelection>(
                      context: context,
                      builder: (_) =>
                          SalesQuoteTemplateMissing(canUpload: canUpload),
                    ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }

      await open(true);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('quote-template-upload')));
      await tester.pumpAndSettle();
      expect(result!.bodyParams['_uploadTemplate'], isTrue);
      await open(false);
      expect(find.byKey(const ValueKey('quote-template-upload')), findsNothing);
      await tester.tap(find.text('Use standard format'));
      await tester.pumpAndSettle();
      expect(result!.bodyParams['templateIds'], isEmpty);
    },
  );

  testWidgets(
    'template mapping review allows changing sheet without adopting it',
    (tester) async {
      TemplateReviewDecision? result;
      await tester.binding.setSurfaceSize(const Size(390, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const mapping = {
        'sheetName': 'Current sheet',
        'mapping': {
          'roles': {'A': 'PART_NO', 'B': 'QTY', 'C': 'UNIT_PRICE'},
          'roleHeaders': {'A': 'MODEL', 'B': 'QUANTITY', 'C': 'UNIT PRICE'},
        },
        'otherSheets': [
          {'index': 2, 'name': 'Alternative'},
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<TemplateReviewDecision>(
                    context: context,
                    builder: (_) => const SalesQuoteTemplateReview(
                      result: mapping,
                      clientName: 'Customer A',
                    ),
                  ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('A · MODEL'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Worksheet: Alternative'));
      await tester.tap(find.text('Worksheet: Alternative'));
      await tester.pumpAndSettle();
      expect(result!.sheetIndex, 2);
    },
  );

  testWidgets(
    'manual field correction rejects duplicates and submits the reviewed roles',
    (tester) async {
      TemplateReviewDecision? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDialog<TemplateReviewDecision>(
                    context: context,
                    builder: (_) => const SalesQuoteTemplateReview(
                      clientName: 'Customer',
                      result: {
                        'mapping': {
                          'roles': {'A': 'PART_NO', 'B': 'QTY', 'C': 'AMOUNT'},
                          'availableHeaders': {
                            'A': 'Model',
                            'B': 'Quantity',
                            'C': 'Custom Price',
                          },
                        },
                      },
                    ),
                  ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      var field = tester.widget<UtenDropdownField>(
        find.byKey(const ValueKey('quote-template-role-C')),
      );
      field.onChanged('QTY');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('quote-template-adopt')),
            )
            .onPressed,
        isNull,
      );
      field = tester.widget<UtenDropdownField>(
        find.byKey(const ValueKey('quote-template-role-C')),
      );
      field.onChanged('UNIT_PRICE');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quote-template-adopt')));
      await tester.pumpAndSettle();
      expect(result!.columnRoles, {
        'A': 'PART_NO',
        'B': 'QTY',
        'C': 'UNIT_PRICE',
      });
    },
  );
}
