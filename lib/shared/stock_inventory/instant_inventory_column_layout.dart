/// Both inventory tables share the declared column order, while keeping
/// independent personal layouts.
const instantInventoryTableKeys = <String>{
  'features.stock.pages.instant_inventory_page.InstantInventoryPageState._buildTablePane.1',
  'master.warehouse.inventory',
};

const instantInventoryColumnLayoutVersion = 2;

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

const _stockDefaultColumnOrder = <String>[
  'name',
  'goodsCode',
  'color',
  'qty',
  'weight',
  'pendingQty',
  'pendingStockInQty',
  'moreQty',
  'stockPlace',
  'owningWarehouse',
  'category',
  'model',
  'spec',
  'cNumber',
  'series',
  'remark',
];

const _periodDefaultColumnOrder = <String>[
  'name',
  'goodsCode',
  'color',
  'qty',
  'costPrice',
  'periodCostAmount',
  'periodInQty',
  'periodOutQty',
  'closingQty',
  'weight',
  'pendingQty',
  'pendingStockInQty',
  'stockPlace',
  'owningWarehouse',
  'category',
  'model',
  'spec',
  'cNumber',
  'series',
  'remark',
];

/// An empty saved order adopts the table's current declared defaults. Only
/// release the exact old default; a reordered, partial, extended or pinned
/// layout represents a personal choice and stays intact. Other preferences
/// belong to the caller and must not be reset with the order.
List<String> migrateInstantInventoryColumnOrder({
  required List<String> order,
  required Set<String> pinned,
  int fromVersion = 0,
}) {
  if (pinned.isNotEmpty) return order;
  final defaults = <List<String>>[
    // A v1 user who deliberately restored the old category-first order keeps it.
    if (fromVersion < 1) _legacyDefaultColumnOrder,
    if (fromVersion < 2) ...[
      _stockDefaultColumnOrder,
      _periodDefaultColumnOrder,
      _periodDefaultColumnOrder
          .where((key) => key != 'costPrice' && key != 'periodCostAmount')
          .toList(),
    ],
  ];
  for (final previous in defaults) {
    if (order.length != previous.length) continue;
    var matches = true;
    for (var i = 0; i < order.length; i++) {
      if (order[i] != previous[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return const [];
  }
  return order;
}
