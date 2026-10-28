/// Goods master layouts share metadata while retaining personal column choices.
const goodsMasterTableKey = 'master.goods';
const goodsColumnLayoutVersion = 1;

// Exact released defaults, verified against the v2.5.29-v2.5.34 source. Price
// and discount columns were emitted only when their own permissions allowed.
const _legacyOrder = <String>[
  'name',
  'clientGoodsName',
  'nameEn',
  'hasBom',
  'code',
  'colorLegacyId',
  'series',
  'owningWarehouse',
  'owningWorkshop',
  'model',
  'cNumber',
  'spec',
  'paper',
  'mouldCode',
  'mouldName',
  'rearInsertCode',
  'unitLegacyId',
  'material',
  'sourceType',
  'price',
  'discount',
  'stockQty',
  'minOrderQty',
  'orderMultipleQty',
];

/// Release only an entire known old preset. Partial, extended, reordered and
/// pinned layouts stay personal; hidden columns, widths and definitions remain
/// the caller's preferences. Empty order adopts the current declared defaults.
List<String> migrateGoodsColumnOrder({
  required List<String> order,
  required Set<String> pinned,
}) {
  if (pinned.isNotEmpty) return order;
  for (final price in [false, true]) {
    for (final discount in [false, true]) {
      final preset = _legacyOrder
          .where(
            (key) =>
                (price || key != 'price') && (discount || key != 'discount'),
          )
          .toList();
      if (order.length != preset.length) continue;
      var matches = true;
      for (var index = 0; index < order.length; index++) {
        if (order[index] != preset[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return const [];
    }
  }
  return order;
}
