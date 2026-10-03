import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/expense/models/expense_guided_values.dart';
import 'package:uten_imp/features/expense/models/expense_item.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_plan.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

AiGuidedFilePlan plan({
  String? amount = '1234.56',
  String? date = '2026-10-03',
  String amountConfidence = 'HIGH',
  String dateConfidence = 'HIGH',
  String? description,
  String descriptionConfidence = 'HIGH',
}) {
  final bytes = Uint8List.fromList([1, 2, 3]);
  return AiGuidedFilePlan(
    jobId: '11111111-1111-4111-8111-111111111111',
    file: PlatformFile(name: 'invoice.csv', size: bytes.length, bytes: bytes),
    workflow: AiGuidedWorkflow.expenseClaim,
    identity: (
      scope: const AuthenticatedScope(userId: 'test-user'),
      server: 'https://fixture.invalid',
      permissions: 'expense:apply',
    ),
    result: AiGuidedFileResult.fromJson({
      'workflow': 'EXPENSE_CLAIM',
      'needsChoice': false,
      'requiresReview': true,
      'fields': {
        'totalAmount': ?amount,
        'issueDate': ?date,
        'itemSummary': ?description,
      },
      'fieldConfidence': {
        'totalAmount': amountConfidence,
        'issueDate': dateConfidence,
        'itemSummary': descriptionConfidence,
      },
      'source': {
        'fileName': 'invoice.csv',
        'sha256': sha256.convert(bytes).toString(),
      },
    }),
  );
}

void main() {
  test('verified amount and issue date become a local editable item', () {
    final item = guidedExpenseItem(plan(description: '办公用品'), 'local-row');
    expect(item?.id, 'local-row');
    expect(item?.amount, 1234.56);
    expect(item?.date, DateTime(2026, 10, 3));
    expect(item?.description, '办公用品');
    // File contents alone do not establish an accounting category.
    expect(item?.category, ExpenseCategory.other);
  });

  test('missing amount or date is not replaced with zero or today', () {
    expect(guidedExpenseItem(plan(amount: null), 'row'), isNull);
    expect(guidedExpenseItem(plan(date: null), 'row'), isNull);
    expect(guidedExpenseItem(plan(amount: ''), 'row'), isNull);
  });

  test('uncertain financial values stay pending for user input', () {
    for (final confidence in ['MEDIUM', 'LOW', '', 'high']) {
      expect(
        guidedExpenseItem(plan(amountConfidence: confidence), 'row'),
        isNull,
      );
      expect(
        guidedExpenseItem(plan(dateConfidence: confidence), 'row'),
        isNull,
      );
    }
  });

  test('invalid dates never roll forward into a different date', () {
    for (final date in [
      '2026-02-30',
      '2025-02-29',
      '2026-13-01',
      '2026-10-00',
      '2026/10/03',
      '2026-10-03T00:00:00Z',
    ]) {
      expect(guidedInvoiceDate(date), isNull, reason: date);
      expect(guidedExpenseItem(plan(date: date), 'row'), isNull, reason: date);
    }
    expect(guidedInvoiceDate('2024-02-29'), DateTime(2024, 2, 29));
  });

  test('unbounded or ambiguous amounts are not coerced into money', () {
    for (final amount in [
      '-12.00',
      '0',
      '0.00',
      '1e5',
      'NaN',
      'Infinity',
      '123.456',
      '1,234.56',
      ' 100.00',
      '1000000000000.00',
    ]) {
      expect(
        guidedExpenseItem(plan(amount: amount), 'row'),
        isNull,
        reason: amount,
      );
    }
    expect(guidedExpenseItem(plan(amount: '0.01'), 'row')?.amount, .01);
  });

  test('uncertain descriptions are not silently promoted to fact', () {
    expect(
      guidedExpenseItem(
        plan(description: '猜测用途', descriptionConfidence: 'LOW'),
        'row',
      )?.description,
      isNull,
    );
    expect(
      guidedExpenseItem(
        plan(description: '物' * 501),
        'row',
      )?.description?.length,
      500,
    );
  });
}
