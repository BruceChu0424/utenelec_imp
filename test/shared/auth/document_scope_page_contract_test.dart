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
      // ADR-108: 写能力来自会话快照, 重试 = 重取快照; 详情加载不再作废能力重拉。
      expect(source, contains('sessionSnapshotProvider.notifier'));
      expect(
        source,
        isNot(contains('ref.invalidate(documentScopeCapabilityProvider')),
      );
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

    // Finance review is pooled across document owners, while imported history
    // remains immutable. Check the actual action expression so an unrelated
    // permission check elsewhere in the page cannot satisfy this boundary.
    for (final action in const {
      'Approve': 'approve',
      'Reverse': 'reverse',
    }.entries) {
      final expression = RegExp(
        'bool\\s+get\\s+_can${action.key}\\s*=>\\s*([^;]+);',
      ).firstMatch(finance)?.group(1);
      expect(expression, isNotNull);
      expect(expression, contains('_canMutate'));
      expect(expression, contains('_hasPermission(_cfg.${action.value}Perm)'));
      expect(expression, isNot(contains('_ordinaryWritable')));
    }
    expect(daily, contains('bool get _canApprove => _allows'));
    expect(daily, contains('bool get _canReverse => _allows'));
    expect(stock, contains('detail.productionLinked || _ordinaryWritable'));
  });
}
