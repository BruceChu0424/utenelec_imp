import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('approval detail actions cannot reopen document amendment flows', () {
    for (final path in [
      'lib/features/production/pages/production_daily_report_detail_page.dart',
      'lib/features/production/pages/production_plan_detail_page.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('修改后审核')), reason: path);
      expect(source, isNot(contains('edit?review=1')), reason: path);
      expect(source, contains("child: const Text('编辑')"), reason: path);
      expect(source, contains("child: const Text('审核')"), reason: path);
    }
  });

  test('retired approval repositories expose no document mutation bridge', () {
    for (final path in [
      'lib/features/production/repositories/production_repository.dart',
      'lib/features/purchase/repositories/purchase_repository.dart',
      'lib/features/subcontract/repositories/subcontract_repository.dart',
      'lib/features/finance/repositories/finance_repository.dart',
      'lib/features/finance/repositories/sales_order_finance_confirmation_repository.dart',
      'lib/features/warehouse/repositories/stock_doc_repository.dart',
    ]) {
      final source = File(path).readAsStringSync();
      for (final obsolete in [
        'saveReviewed(',
        'updateReviewed(',
        'amendReview(',
        'draft-review',
      ]) {
        expect(source, isNot(contains(obsolete)), reason: '$path: $obsolete');
      }
    }
  });
}
