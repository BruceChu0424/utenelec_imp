import 'package:uten_imp/features/finance/models/finance_doc.dart';

String financeReviewFixtureScope(FinanceDocType type) => switch (type) {
  FinanceDocType.receipt => 'finance_receipt',
  FinanceDocType.payment => 'finance_payment',
  FinanceDocType.expense => 'finance_expense',
  FinanceDocType.otherIncome => 'finance_other_income',
  FinanceDocType.bankTransfer => 'finance_bank_transfer',
};
Map<String, dynamic> financeReviewedDetailFixture(
  Map<String, dynamic> source,
  FinanceDocType type,
) => {
  ...source,
  'approvalVersion':
      type == FinanceDocType.receipt || type == FinanceDocType.payment
      ? source['version']
      : null,
  'approvalSnapshot': List.filled(64, 'a').join(),
  'approvalPlatformFields': {
    financeReviewFixtureScope(type): [
      {'recordId': source['id'], 'cells': <Object>[]},
    ],
    '${financeReviewFixtureScope(type)}_item': [
      for (final item in source['items'] as List? ?? <Object>[])
        {'recordId': (item as Map)['id'], 'cells': <Object>[]},
    ],
  },
};
Map<String, dynamic> financeReviewReceiptFixture({
  required String path,
  required Map<String, dynamic> command,
  required Map<String, dynamic> result,
  String actorId = 'native-detail-reader',
  String operation = 'FINANCE_DOCUMENT_UPDATE',
}) => {
  'found': true,
  'outcome': 'SUCCEEDED',
  'actorId': actorId,
  'requestId': command['requestId'],
  'operation': operation,
  'method': operation == 'FINANCE_DOCUMENT_UPDATE' ? 'PUT' : 'POST',
  'path': path,
  'requestBody': command,
  'result': result,
  'precisionChoices': <String, dynamic>{},
  'precisionContext': {
    'available': true,
    'choices': <String, dynamic>{},
    'usedChoices': <String, dynamic>{},
  },
};
