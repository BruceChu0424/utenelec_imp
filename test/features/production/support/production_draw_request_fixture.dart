Map<String, dynamic> productionDrawRequestFixture({
  int version = 7,
  String fingerprint = 'preview-fingerprint',
}) => {
  'fingerprint': fingerprint,
  'taskCount': 2,
  'documentCount': 2,
  'lineCount': 3,
  'tasks': [
    for (final id in ['a', 'b'])
      {
        'segmentId': id,
        'expectedVersion': version,
        'planId': 'plan-$id',
        'planNo': 'SC-$id',
        'segmentCode': 'CJ-$id',
        'workshopDepartmentId': 'workshop',
        'workshopName': '装配车间',
        'productCode': 'CP-$id',
        'productName': '产品$id',
        'plannedQty': 10,
      },
  ],
  'lines': [
    {
      ..._material('warehouse-a', 3),
      'segmentId': 'a',
      'drawId': 'draw-a',
      'drawNo': 'LL-a',
      'drawItemId': 'line-a',
    },
    {
      ..._material('warehouse-a', 4),
      'segmentId': 'b',
      'drawId': 'draw-b',
      'drawNo': 'LL-b',
      'drawItemId': 'line-b',
    },
    {
      ..._material('warehouse-b', 2),
      'segmentId': 'b',
      'drawId': 'draw-b',
      'drawNo': 'LL-b',
      'drawItemId': 'line-c',
    },
  ],
  'summaries': [_material('warehouse-a', 7), _material('warehouse-b', 2)],
};

Map<String, dynamic> _material(String warehouseId, num qty) => {
  'warehouseId': warehouseId,
  // Identical names deliberately exercise stable UUID matching.
  'warehouseName': '原料仓',
  'goodsId': 'goods',
  'goodsCode': 'WL-001',
  'goodsName': '铝件',
  'colorId': 'silver',
  'colorName': '银色',
  'unitId': 'unit',
  'unitName': '个',
  'qty': qty,
};

const productionDrawRequestResultFixture = {
  'segmentIds': ['a', 'b'],
  'documentIds': ['draw-a', 'draw-b'],
  'taskCount': 2,
  'documentCount': 2,
  'replayed': false,
};
