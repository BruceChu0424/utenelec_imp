/// 即时库存总览的可恢复筛选范围；URL 保留筛选事实，刷新/直接打开不依赖内存快照。
class InstantInventoryScope {
  const InstantInventoryScope({
    this.categoryId,
    this.warehouseId,
    this.includeDefective = false,
    this.includeLineSide = false,
    this.keyword,
    this.owningWarehouse,
    this.owningWarehouseNull = false,
    this.colorId,
    this.series,
    this.unitId,
    this.colorNull = false,
    this.inventoryOnly = true,
  });

  /// Legacy goods inventory panel: every warehouse, including non-accountable
  /// and line-side locations. This is explicit and never an implicit bool reset.
  const InstantInventoryScope.full({
    String? warehouseId,
    String? colorId,
    bool colorNull = false,
  }) : this(
         warehouseId: warehouseId,
         colorId: colorId,
         colorNull: colorNull,
         inventoryOnly: false,
         includeLineSide: true,
       );

  final String? categoryId;
  final String? warehouseId;
  final bool includeDefective;
  final bool includeLineSide;
  final String? keyword;
  final String? owningWarehouse;
  final bool owningWarehouseNull;
  final String? colorId;
  final String? series;
  final String? unitId;
  final bool colorNull;
  final bool inventoryOnly;

  factory InstantInventoryScope.fromQuery(
    Map<String, String> query, {
    bool inventoryDefault = true,
  }) {
    String? value(String key) {
      final text = query[key]?.trim();
      return text == null || text.isEmpty ? null : text;
    }

    final color = value('colorId');
    final noColor = query['colorNull'] == 'true';
    if (color != null && noColor) throw const FormatException('颜色与无颜色不能同时筛选');
    final inventory = query.containsKey('inventoryOnly')
        ? query['inventoryOnly'] == 'true'
        : inventoryDefault;
    return InstantInventoryScope(
      categoryId: value('categoryId'),
      warehouseId: value('warehouseId'),
      // ADR-146: 不良品仓默认不计入，只有显式打开才算。
      includeDefective: query['includeDefective'] == 'true',
      includeLineSide: query.containsKey('includeLineSide')
          ? query['includeLineSide'] == 'true'
          : !inventory,
      keyword: value('keyword'),
      owningWarehouse: value('owningWarehouse'),
      owningWarehouseNull: query['owningWarehouseNull'] == 'true',
      colorId: color,
      colorNull: noColor,
      inventoryOnly: inventory,
      series: value('series'),
      unitId: value('unitId'),
    );
  }

  Map<String, String> toQuery() => {
    'categoryId': ?categoryId,
    'warehouseId': ?warehouseId,
    'includeDefective': '$includeDefective',
    'includeLineSide': '$includeLineSide',
    'keyword': ?keyword,
    'owningWarehouse': ?owningWarehouse,
    if (owningWarehouseNull) 'owningWarehouseNull': 'true',
    'colorId': ?colorId,
    'series': ?series,
    'unitId': ?unitId,
    if (colorNull) 'colorNull': 'true',
    if (!inventoryOnly) 'inventoryOnly': 'false',
  };

  /// Geometry and warehouse type rules for context, balances and ledger APIs.
  Map<String, dynamic> toQueryParameters() {
    if (colorId != null && colorNull) {
      throw const FormatException('颜色与无颜色不能同时筛选');
    }
    return {
      'warehouseId': ?warehouseId,
      'colorId': ?colorId,
      if (colorNull) 'colorNull': true,
      'inventoryOnly': inventoryOnly,
      'includeDefective': includeDefective,
      'includeLineSide': includeLineSide,
    };
  }

  InstantInventoryScope withDimensions({
    String? warehouseId,
    String? colorId,
    bool colorNull = false,
  }) => InstantInventoryScope(
    warehouseId: warehouseId,
    colorId: colorId,
    colorNull: colorNull,
    inventoryOnly: inventoryOnly,
    includeDefective: includeDefective,
    includeLineSide: includeLineSide,
  );

  InstantInventoryScope get allWarehouses =>
      InstantInventoryScope.full(colorId: colorId, colorNull: colorNull);

  String label({
    String? warehouseName,
    String? colorName,
    bool warehouseHasChildren = true,
  }) => [
    warehouseId == null
        ? inventoryOnly
              ? '全部核算仓库'
              : '全部仓库（含非核算仓）'
        : '所选仓库及下级：${warehouseName == null || warehouseName == '—' ? warehouseId : warehouseName}',
    if (inventoryOnly && (warehouseId == null || warehouseHasChildren))
      includeDefective ? '含不良品仓' : '不含不良品仓',
    if (inventoryOnly && (warehouseId == null || warehouseHasChildren))
      includeLineSide ? '含内料仓' : '不含内料仓',
    if (inventoryOnly && warehouseId != null && !warehouseHasChildren)
      '叶仓精确查询（仓类型开关不排除所选仓）',
    if (!inventoryOnly) '含不良品仓及内料仓',
    colorId != null
        ? '颜色：${colorName == null || colorName == '—' ? colorId : colorName}'
        : colorNull
        ? '无颜色'
        : '全部颜色',
  ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is InstantInventoryScope &&
      categoryId == other.categoryId &&
      warehouseId == other.warehouseId &&
      includeDefective == other.includeDefective &&
      includeLineSide == other.includeLineSide &&
      keyword == other.keyword &&
      owningWarehouse == other.owningWarehouse &&
      owningWarehouseNull == other.owningWarehouseNull &&
      colorId == other.colorId &&
      series == other.series &&
      unitId == other.unitId &&
      colorNull == other.colorNull &&
      inventoryOnly == other.inventoryOnly;

  @override
  int get hashCode => Object.hash(
    categoryId,
    warehouseId,
    includeDefective,
    includeLineSide,
    keyword,
    owningWarehouse,
    owningWarehouseNull,
    colorId,
    series,
    unitId,
    colorNull,
    inventoryOnly,
  );

  String get fallbackLabel => [
    categoryId == null ? '全部分类' : '所选分类',
    warehouseId == null ? '全部仓库' : '所选仓库',
    includeDefective ? '含不良品仓' : '不含不良品仓',
    includeLineSide ? '含内料仓' : '不含内料仓',
    if (keyword != null) '搜索：$keyword',
    if (owningWarehouse != null) '已筛选归属仓库',
    if (owningWarehouseNull) '归属仓库未登记',
    if (colorId != null) '已筛选颜色',
    if (colorNull) '无颜色',
    if (series != null) '物料系列：$series',
    if (unitId != null) '已筛选单位',
  ].join(' · ');
}
