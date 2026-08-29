import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _source(String path) => File(path).readAsStringSync();

String _between(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, isNonNegative, reason: 'missing start marker: $start');
  expect(endIndex, greaterThan(startIndex), reason: 'missing end marker: $end');
  return source.substring(startIndex, endIndex);
}

void main() {
  test('core approval surfaces identify the current reviewer', () {
    final expectedMarkers = <String, List<String>>{
      'lib/features/sales/pages/sales_doc_detail_page.dart': [
        'reviewerResponsibility: true',
        "actionLabel: '财务审核发货'",
      ],
      'lib/features/warehouse/pages/stock_doc_detail_page.dart': [
        'reviewerResponsibility: true',
      ],
      'lib/features/finance/pages/finance_doc_detail_page.dart': [
        'reviewerResponsibility: true',
        "reviewerActionLabel: '费用单总账确认'",
      ],
      'lib/features/production/pages/production_daily_report_detail_page.dart':
          ['reviewerResponsibility: true'],
      'lib/features/production/pages/production_plan_detail_page.dart': [
        'reviewerResponsibility: true',
      ],
      'lib/features/production/pages/production_plan_list_page.dart': [
        "actionLabel: '批量审核'",
      ],
      'lib/features/production/pages/production_plan_wizard_page.dart': [
        "actionLabel: '生产计划审核下达'",
      ],
      'lib/features/expense/pages/expense_approval_detail_page.dart': [
        "actionLabel: '报销审批'",
      ],
      'lib/features/finance/pages/finance_sales_order_review_page.dart': [
        "actionLabel: '销售订单财务确认'",
        "actionLabel: '销售订单财务驳回'",
      ],
      'lib/features/payroll/pages/payroll_review_page.dart': [
        "actionLabel: '工资审核'",
        "actionLabel: '工资审核驳回'",
      ],
      'lib/features/visitor_approval/pages/visitor_approval_detail_page.dart': [
        "actionLabel: '访客审批通过'",
        "actionLabel: '访客审批拒绝'",
      ],
      'lib/features/finance/widgets/finance_asset_detail.dart': [
        '_assetReviewerActions',
        'UtenReviewerResponsibilityNotice(',
      ],
      'lib/features/finance/widgets/finance_asset_posting_panel.dart': [
        "actionLabel: '资产计提批次审批'",
      ],
      'lib/features/finance/widgets/finance_asset_policy_dialog.dart': [
        "actionLabel: '会计政策审核并启用'",
      ],
    };

    for (final entry in expectedMarkers.entries) {
      final source = _source(entry.key);
      expect(
        source,
        contains('uten_reviewer_responsibility_notice.dart'),
        reason: '${entry.key} must import the shared responsibility notice',
      );
      for (final marker in entry.value) {
        expect(source, contains(marker), reason: '${entry.key}: $marker');
      }
    }
  });

  test('review responsibility remains opt-in for actual review actions', () {
    final sales = _source(
      'lib/features/sales/pages/sales_doc_detail_page.dart',
    );
    expect(
      _between(sales, 'Future<void> _approve()', 'Future<void> _reverse()'),
      contains('reviewerResponsibility: true'),
    );
    expect(
      _between(sales, 'Future<void> _reverse()', 'Future<void> _cancel'),
      isNot(contains('reviewerResponsibility: true')),
    );

    final plans = _source(
      'lib/features/production/pages/production_plan_list_page.dart',
    );
    expect(
      _between(
        plans,
        'Future<void> _batchApprove()',
        'Future<void> _batchDelete()',
      ),
      contains('reviewerResponsibility: true'),
    );
    expect(
      _between(plans, 'Future<void> _batchDelete()', 'Future<void> _runBatch'),
      isNot(contains('reviewerResponsibility: true')),
    );
  });
}
