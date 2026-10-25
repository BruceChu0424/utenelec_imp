/// Both inventory tables share the declared column order, while keeping
/// independent personal layouts.
const instantInventoryTableKeys = <String>{
  'features.stock.pages.instant_inventory_page.InstantInventoryPageState._buildTablePane.1',
  'master.warehouse.inventory',
};

const instantInventoryColumnLayoutVersion = 1;

const _legacyDefaultColumnOrder = <String>[
  'category',
  'name',
  'goodsCode',
  'color',
  'series',
  'stockPlace',
  'owningWarehouse',
  'model',
  'cNumber',
  'spec',
  'remark',
  'qty',
  'weight',
  'pendingQty',
  'pendingStockInQty',
  'moreQty',
];

/// An empty saved order adopts the table's current declared defaults. Only
/// release the exact old default; a reordered, partial, extended or pinned
/// layout represents a personal choice and stays intact. Other preferences
/// belong to the caller and must not be reset with the order.
List<String> migrateInstantInventoryColumnOrder({
  required List<String> order,
  required Set<String> pinned,
}) {
  if (pinned.isNotEmpty || order.length != _legacyDefaultColumnOrder.length) {
    return order;
  }
  for (var i = 0; i < order.length; i++) {
    if (order[i] != _legacyDefaultColumnOrder[i]) return order;
  }
  return const [];
}
