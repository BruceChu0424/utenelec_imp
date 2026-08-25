import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all shared document details consume fail-closed owner capability', () {
    for (final path in const [
      'lib/features/finance/pages/finance_doc_detail_page.dart',
      'lib/features/purchase/pages/purchase_doc_detail_page.dart',
      'lib/features/subcontract/pages/subcontract_doc_detail_page.dart',
      'lib/features/production/pages/production_plan_detail_page.dart',
      'lib/features/production/pages/production_daily_report_detail_page.dart',
      'lib/features/warehouse/pages/stock_doc_detail_page.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('documentScopeCapabilityProvider'));
      expect(source, contains('documentOwnerCanWrite'));
      expect(source, contains('DocumentScopeWriteNotice'));
      expect(source, contains('onRetry:'));
      expect(source, contains('ref.invalidate'));
    }
  });

  test(
    'all direct edit routes fail closed before populating editable state',
    () {
      for (final path in const [
        'lib/features/finance/pages/finance_doc_edit_page.dart',
        'lib/features/purchase/pages/purchase_doc_edit_page.dart',
        'lib/features/subcontract/pages/subcontract_doc_edit_page.dart',
        'lib/features/production/pages/production_plan_edit_page.dart',
        'lib/features/production/pages/production_daily_report_edit_page.dart',
        'lib/features/warehouse/pages/stock_doc_edit_page.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, contains('loadDocumentOwnerCanWrite'));
        expect(source, contains('documentScopeReadOnlyMessage'));
        expect(source, contains('context.replace'));
      }
    },
  );

  test('pooled and production-linked exceptions stay explicit', () {
    final finance = File(
      'lib/features/finance/pages/finance_doc_detail_page.dart',
    ).readAsStringSync();
    final daily = File(
      'lib/features/production/pages/production_daily_report_detail_page.dart',
    ).readAsStringSync();
    final stock = File(
      'lib/features/warehouse/pages/stock_doc_detail_page.dart',
    ).readAsStringSync();

    expect(finance, contains('bool get _canApprove => _hasPermission'));
    expect(finance, contains('bool get _canReverse => _hasPermission'));
    expect(daily, contains('bool get _canApprove => _allows'));
    expect(daily, contains('bool get _canReverse => _allows'));
    expect(stock, contains('detail.productionLinked || _ordinaryWritable'));
  });
}
