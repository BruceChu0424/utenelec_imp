/// Shared business column order for sales entry, review and retained revisions.
const salesDocumentColumnKeys = <String>[
  'goods',
  'nameEn',
  'goodsCode',
  'color',
  'clientModel',
  'clientGoodsName',
  'qty',
  'price',
  'discount',
  'clientPrice',
  'amount',
  'remark',
];

String salesDocumentColumnKey(String key) => switch (key) {
  'goodsName' => 'goods',
  '英文名称' => 'nameEn',
  'colorName' || '颜色' => 'color',
  '数量' => 'qty',
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
