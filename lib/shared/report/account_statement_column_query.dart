import '../models/master_facet_bucket.dart';

/// Fixed chronology preserves the meaning of each account running balance.
const accountStatementSearchKeys = {
  'billDate',
  'settledDate',
  'billNo',
  'checkNo',
  'summary',
  'counterpartName',
  'source',
  'inAmount',
  'outAmount',
  'balance',
};
const accountStatementChoiceKeys = {'sourceDocType', 'entryKind'};

const accountStatementEntryKinds = [
  MasterFacetBucket(value: 'POSTING', label: '原始入账', count: 0),
  MasterFacetBucket(value: 'REVERSAL', label: '反向流水', count: 0),
  MasterFacetBucket(value: 'ADJUSTMENT', label: '余额调整', count: 0),
];
const accountStatementSources = [
  MasterFacetBucket(value: 'RECEIPT', label: '收款', count: 0),
  MasterFacetBucket(value: 'RECEIPT_FEE', label: '收款手续费', count: 0),
  MasterFacetBucket(value: 'PAYMENT', label: '付款', count: 0),
  MasterFacetBucket(value: 'EXPENSE', label: '费用', count: 0),
  MasterFacetBucket(value: 'INCOME', label: '其他收入', count: 0),
  MasterFacetBucket(value: 'BANK_TRANSFER', label: '银行转账', count: 0),
  MasterFacetBucket(value: 'BALANCE_ADJUSTMENT', label: '余额校准', count: 0),
  MasterFacetBucket(
    value: 'SUPPLIER_CLAIM_RECEIPT',
    label: '供应商索赔收款',
    count: 0,
  ),
];

String? accountStatementChoiceLabel(
  List<MasterFacetBucket> choices,
  String? value,
) {
  for (final choice in choices) {
    if (choice.value == value) return choice.display;
  }
  return value;
}

Map<String, dynamic> accountStatementColumnParameters(
  Map<String, String?> values,
) => {
  for (final entry in values.entries)
    if (entry.value?.trim().isNotEmpty == true &&
        (accountStatementChoiceKeys.contains(entry.key) ||
            (entry.key.startsWith('search.') &&
                accountStatementSearchKeys.contains(entry.key.substring(7)))))
      entry.key: entry.value!.trim(),
};
