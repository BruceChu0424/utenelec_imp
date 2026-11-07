/// Shared business column order for sales entry, review and retained revisions.
const salesDocumentColumnKeys = <String>[
  'goods',
  'nameEn',
  'goodsCode',
  'color',
  'clientModel',
  'clientGoodsName',
  'qty',
  'deliveryPlan',
  'price',
  'discount',
  'clientPrice',
  'amount',
  'currency',
  'remark',
];

const salesOrderItemsTableKey = 'sales.order.items';
const salesOrderColumnLayoutVersion = 1;

/// The platform table profile and the declared business columns must agree on
/// which fields are visible. Optional customer/pricing fields stay opt-in.
List<String> salesDocumentDefaultColumns({required bool order}) => [
  'goods',
  'nameEn',
  'goodsCode',
  'color',
  'qty',
  if (order) 'deliveryPlan',
  'unit',
  'price',
  'discount',
  'amount',
  'currency',
  'remark',
];

/// Version 0's platform profile hid deliveryPlan, including when another
/// column change persisted that unintended hidden state. Repair just that
/// field once; subsequent versions retain the user's own hide/order choices.
({List<String> order, Set<String> hidden})
migrateSalesOrderDeliveryColumnLayout({
  required List<String> order,
  required Set<String> hidden,
}) {
  final migrated = order.where((key) => key != 'deliveryPlan').toList();
  if (order.isNotEmpty) {
    final quantity = migrated.indexOf('qty');
    final price = migrated.indexOf('price');
    migrated.insert(
      quantity >= 0 ? quantity + 1 : (price >= 0 ? price : migrated.length),
      'deliveryPlan',
    );
  }
  return (
    order: List.unmodifiable(migrated),
    hidden: Set.unmodifiable({...hidden}..remove('deliveryPlan')),
  );
}

String salesDocumentColumnKey(String key) => switch (key) {
  'goodsName' => 'goods',
  '英文名称' => 'nameEn',
  'colorName' || '颜色' => 'color',
  '数量' => 'qty',
  '交付方式' => 'deliveryPlan',
  '单价' => 'price',
  '折扣' => 'discount',
  '原币金额' => 'amount',
  '客户型号' => 'clientModel',
  '客户文件品名' => 'clientGoodsName',
  '客户文件单价' => 'clientPrice',
  '备注' => 'remark',
  _ => key,
};

List<T> canonicalSalesColumns<T>(
  List<T> columns, {
  required String Function(T) keyOf,
  bool enabled = true,
}) {
  if (!enabled) return columns;
  final indexed = columns.indexed.toList();
  int rank(T column) {
    final index = salesDocumentColumnKeys.indexOf(
      salesDocumentColumnKey(keyOf(column)),
    );
    return index < 0 ? salesDocumentColumnKeys.length : index;
  }

  indexed.sort((a, b) {
    final comparison = rank(a.$2).compareTo(rank(b.$2));
    return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
  });
  return [for (final entry in indexed) entry.$2];
}
