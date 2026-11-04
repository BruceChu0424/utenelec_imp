import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/expense/pages/expense_item_dialog.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';

void main() {
  for (final raw in [
    '100.123456789012345678901234',
    '1234567890123456789012345678901234567890.123456789012345678901234',
  ]) {
    testWidgets('actual item dialog accepts complete supported amount $raw', (
      tester,
    ) async {
      ExpenseItem? saved;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<ExpenseItem>(
                    context: context,
                    builder: (_) => const ExpenseItemDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.first, raw);
      await tester.enterText(fields.last, '原始费用完整金额');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(saved?.amountText, raw);
      expect(saved?.toCreateJson()['amount'], raw);
      expect(find.byType(ExpenseItemDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('expense purpose is required before accepting an item', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const ExpenseItemDialog(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '金额 *'), '80.01');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpenseItemDialog), findsOneWidget);
    final fields = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .toList();
    expect(fields.last.validator!('  '), '请填写费用用途');
    expect(fields.last.validator!('客户拜访交通费'), isNull);
  });
}
