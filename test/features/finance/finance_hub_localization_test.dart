import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';

void main() {
  test('finance descriptions match the shared queues and bank transfer', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    final en = lookupAppLocalizations(const Locale('en'));
    final ko = lookupAppLocalizations(const Locale('ko'));
    expect(zh.financeHubTaskApprovalSub, '采购与委外订货审批');
    expect(
      en.financeHubTaskApprovalSub,
      'Purchase and subcontract order approvals',
    );
    expect(ko.financeHubTaskApprovalSub, '구매 및 외주 주문 승인');
    expect(zh.financeHubDocBankTransferSub, '账户之间转账');
  });
}
