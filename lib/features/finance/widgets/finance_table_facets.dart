import '../../basic_data/models/master_facet.dart';

List<MasterFacetBucket> financeDictionaryFacets(Map<String, String> entries) {
  final sorted = entries.entries.toList(growable: false)
    ..sort((a, b) => a.value.compareTo(b.value));
  return [
    for (final entry in sorted)
      MasterFacetBucket(value: entry.key, label: entry.value, count: 0),
  ];
}

const financeDocumentStatusFacets = <MasterFacetBucket>[
  MasterFacetBucket(value: '0', label: '草稿', count: 0),
  MasterFacetBucket(value: '1', label: '已审', count: 0),
  MasterFacetBucket(value: '2', label: '红冲', count: 0),
];

const financeArApDirectionFacets = <MasterFacetBucket>[
  MasterFacetBucket(value: 'AR', label: '应收', count: 0),
  MasterFacetBucket(value: 'AP', label: '应付', count: 0),
];

const financeArApSettledFacets = <MasterFacetBucket>[
  MasterFacetBucket(value: 'false', label: '未清', count: 0),
  MasterFacetBucket(value: 'true', label: '已清', count: 0),
];

const financeArApSourceTypeFacets = <MasterFacetBucket>[
  MasterFacetBucket(value: 'SALES_SHIPMENT', label: '销售发运', count: 0),
  MasterFacetBucket(value: 'SALES_RETURN', label: '销售退货', count: 0),
  MasterFacetBucket(value: 'DIRECT_RECEIPT', label: '财务直接预收', count: 0),
  MasterFacetBucket(value: 'PURCHASE_RECEIPT', label: '采购收货', count: 0),
  MasterFacetBucket(value: 'PURCHASE_RETURN', label: '采购退货', count: 0),
  MasterFacetBucket(value: 'SUBCONTRACT_RECEIPT', label: '委外进仓', count: 0),
  MasterFacetBucket(value: 'SUBCONTRACT_RETURN', label: '委外退货', count: 0),
  MasterFacetBucket(value: 'SUBCONTRACT_WASTE', label: '委外损耗扣款', count: 0),
  MasterFacetBucket(value: 'OPENING_BALANCE', label: '期初余额', count: 0),
  MasterFacetBucket(value: 'MANUAL_AR', label: '手工应收', count: 0),
  MasterFacetBucket(value: 'MANUAL_AP', label: '手工应付', count: 0),
];

const financeReconciliationSourceFacets = <MasterFacetBucket>[
  MasterFacetBucket(value: 'RECEIPT', label: '销售收款', count: 0),
  MasterFacetBucket(value: 'PAYMENT', label: '采购付款', count: 0),
  MasterFacetBucket(value: 'EXPENSE', label: '一般费用', count: 0),
  MasterFacetBucket(value: 'INCOME', label: '其它收入', count: 0),
  MasterFacetBucket(value: 'BANK_TRANSFER', label: '银行存取', count: 0),
  MasterFacetBucket(value: 'BALANCE_ADJUSTMENT', label: '余额调整', count: 0),
];

const financePayablesBusinessTypeFacets = <MasterFacetBucket>[
  MasterFacetBucket(value: 'PURCHASE', label: '采购', count: 0),
  MasterFacetBucket(value: 'SUBCONTRACT', label: '委外', count: 0),
];

const financePayablesStatusFacets = <MasterFacetBucket>[
  MasterFacetBucket(value: 'OPEN', label: '未付', count: 0),
  MasterFacetBucket(value: 'PARTIAL', label: '部分付款', count: 0),
  MasterFacetBucket(value: 'SETTLED', label: '已结清', count: 0),
  MasterFacetBucket(value: 'OVERDUE', label: '已逾期', count: 0),
  MasterFacetBucket(value: 'CREDIT', label: '贷项/负应付', count: 0),
  MasterFacetBucket(value: 'UNDATED', label: '未定到期日', count: 0),
  MasterFacetBucket(value: 'PREPAYMENT', label: '供应商预付款', count: 0),
  MasterFacetBucket(value: 'CLAIM_CREDIT', label: '委外索赔贷项', count: 0),
  MasterFacetBucket(value: 'FROZEN', label: '已冻结', count: 0),
];
