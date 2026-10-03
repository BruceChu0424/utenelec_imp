// 单货品库存面板模型 (ADR-135 §6.3/§7.1/§7.4): 出入库流水页 + 单货品 KPI 条。
//
// - 流水行 = 库存流水 (rowKind 'M') 与重量调整 (rowKind 'W') 按过账顺序合并;
//   结存数量/结存重量由服务端按「仓库(含下级) + 颜色」范围算好 (与类型筛选无关),
//   前端不做任何加减。
// - 类型文案一律由服务端给 (红冲带「(红冲)」; 重量调整行为调整种类名), 前端不再翻译。
// - 重量来历 (weightSource) 由服务端给, 老数据有重量无来历时服务端已按「实称」下发。
// - 表头筛选桶原样使用: 颜色的「无颜色」桶值为 [kMasterFilterNullValue] ('__null__'),
//   选它即按 colorNull 查询。
// - 来源单据跳转只认服务端 sourceDocType + sourceDocCode (仓库单据的 doc_type),
//   不再按 movement_type 猜单据类型。
// - 重量一律千克; null = 没称/未知, 永远不当 0。
import '../../core/router/route_names.dart';
import '../../features/basic_data/models/master_facet.dart';
import '../measurement/weight_predictor.dart';
import '../../features/stock/models/instant_inventory_scope.dart';

/// 库存面板三个分段 (路由 ?tab= 用 [key])。
enum GoodsStockLedgerSegment {
  balance('balance', '库存余额'),
  ledger('ledger', '出入库流水'),
  weight('weight', '单重学习');

  const GoodsStockLedgerSegment(this.key, this.label);

  final String key;
  final String label;

  /// 路由参数 -> 分段; 认不出回落「库存余额」。
  static GoodsStockLedgerSegment parse(String? raw) {
    final key = raw?.trim().toLowerCase();
    for (final s in GoodsStockLedgerSegment.values) {
      if (s.key == key) return s;
    }
    return GoodsStockLedgerSegment.balance;
  }
}

/// 流水查询条件 (GET /stock/goods/{goodsId}/ledger)。
class StockLedgerQuery {
  const StockLedgerQuery({
    this.warehouseId,
    this.colorId,
    this.colorNull = false,
    this.dateFrom,
    this.dateTo,
    this.movementTypes = const [],
    this.direction,
    this.includeWeightAdjustments = false,
    this.page = 1,
    this.size = 50,
    this.scope,
  });

  /// 仓库 (服务端按含下级展开); null = 全部。
  final String? warehouseId;
  final String? colorId;

  /// 只看无颜色的维度。
  final bool colorNull;

  /// 业务日期 (含两端, 中国日期)。
  final DateTime? dateFrom;
  final DateTime? dateTo;

  /// 类型码 (1..20, 'W' = 重量调整); 空 = 全部。
  final List<String> movementTypes;

  /// 1 = 只看收入, -1 = 只看发出; null = 全部。
  final int? direction;
  final bool includeWeightAdjustments;
  final int page;

  /// 服务端上限 100。
  final int size;
  final InstantInventoryScope? scope;

  Map<String, dynamic> toQueryParameters() => {
    if (scope == null) ...{
      'warehouseId': ?warehouseId,
      if (colorNull) 'colorNull': true else 'colorId': ?colorId,
    } else
      ...scope!.toQueryParameters(),
    if (dateFrom != null) 'dateFrom': _isoDate(dateFrom!),
    if (dateTo != null) 'dateTo': _isoDate(dateTo!),
    if (movementTypes.isNotEmpty) 'movementTypes': movementTypes.join(','),
    'direction': ?direction,
    if (includeWeightAdjustments) 'includeWeightAdjustments': true,
    'page': page,
    'size': size > 100 ? 100 : size,
  };
}

/// 一行流水 (库存流水或重量调整)。
class StockLedgerRow {
  const StockLedgerRow({
    required this.rowKind,
    required this.id,
    this.transactionDate,
    this.movementType,
    this.typeLabel,
    this.direction,
    this.sourceDocType,
    this.sourceDocId,
    this.sourceDocCode,
    this.billNo,
    this.counterpartKind,
    this.counterpartName,
    this.counterpartMasked = false,
    this.warehouseId,
    this.warehouseName,
    this.colorId,
    this.colorName,
    this.qtySigned,
    this.unitName,
    this.weightKgSigned,
    this.weightSource,
    this.adjustmentKind,
    this.balanceQtyAfter,
    this.balanceWeightKgAfter,
    this.remark,
    this.operatorName,
    this.amountLocal,
    this.costMasked = false,
  });

  /// 'M' = 库存流水; 'W' = 重量调整 (只改重量, 不动数量)。
  final String rowKind;
  final String id;
  final String? transactionDate;
  final int? movementType;

  /// 服务端类型文案 (红冲带「(红冲)」; 重量调整行为 重量起算/重量尾差调整/盘点定重/人工核重/撤销盘点重量)。
  final String? typeLabel;
  final int? direction;
  final String? sourceDocType;
  final String? sourceDocId;

  /// 仓库单据的 doc_type (如 DRAW / WASTE / CHECK), 用于跳转。
  final String? sourceDocCode;
  final String? billNo;
  final String? counterpartKind;
  final String? counterpartName;

  /// 往来方名称因权限被隐藏。
  final bool counterpartMasked;
  final String? warehouseId;
  final String? warehouseName;
  final String? colorId;
  final String? colorName;

  /// 带符号数量 (基本单位; 收入为正、发出为负; 重量调整行为 null)。
  final double? qtySigned;
  final String? unitName;

  /// 带符号重量 (千克); null = 没称/未知。
  final double? weightKgSigned;

  /// MEASURED / EXACT / SLICE / AVERAGE / ESTIMATE (重量来历; 重量未知或重量调整行为 null)。
  final String? weightSource;

  /// 重量调整种类: ANCHOR / RESIDUAL / COUNT / MANUAL / REVERSAL。
  final String? adjustmentKind;
  final double? balanceQtyAfter;

  /// 本行之后的结存重量 (千克); null = 未知。
  final double? balanceWeightKgAfter;
  final String? remark;
  final String? operatorName;
  final double? amountLocal;
  final bool costMasked;

  bool get isWeightAdjustment => rowKind.toUpperCase() == 'W';

  /// 收入 (数量为正; 重量调整行按重量增减判断)。
  bool get isInbound {
    if (isWeightAdjustment) return (weightKgSigned ?? 0) > 0;
    final q = qtySigned;
    if (q != null && q != 0) return q > 0;
    return (direction ?? 0) > 0;
  }

  /// 类型列文案 (服务端给)。
  String get displayType => typeLabel ?? '—';

  factory StockLedgerRow.fromJson(Map<String, dynamic> j) => StockLedgerRow(
    rowKind: _str(j['rowKind']) ?? 'M',
    id: (j['id'] ?? '').toString(),
    transactionDate: _str(j['transactionDate']),
    movementType: _int(j['movementType']),
    typeLabel: _str(j['typeLabel']),
    direction: _int(j['direction']),
    sourceDocType: _str(j['sourceDocType']),
    sourceDocId: _str(j['sourceDocId']),
    sourceDocCode: _str(j['sourceDocCode']),
    billNo: _str(j['billNo']),
    counterpartKind: _str(j['counterpartKind']),
    counterpartName: _str(j['counterpartName']),
    counterpartMasked: j['counterpartMasked'] == true,
    warehouseId: _str(j['warehouseId']),
    warehouseName: _str(j['warehouseName']),
    colorId: _str(j['colorId']),
    colorName: _str(j['colorName']),
    qtySigned: _num(j['qtySigned']),
    unitName: _str(j['unitName']),
    weightKgSigned: _num(j['weightKgSigned']),
    weightSource: _str(j['weightSource']),
    adjustmentKind: _str(j['adjustmentKind']),
    balanceQtyAfter: _num(j['balanceQtyAfter']),
    balanceWeightKgAfter: _num(j['balanceWeightKgAfter']),
    remark: _str(j['remark']),
    operatorName: _str(j['operatorName']),
    amountLocal: _num(j['amountLocal']),
    costMasked: j['costMasked'] == true,
  );
}

/// 期初/本期/期末汇总 (服务端一次聚合; 类型筛选只影响本期收入/发出)。
class StockLedgerSummary {
  const StockLedgerSummary({
    this.openingQty,
    this.closingQty,
    this.inQty,
    this.outQty,
    this.internalTransferQty,
    this.openingWeightKg,
    this.closingWeightKg,
    this.inWeightKg,
    this.outWeightKg,
    this.inWeightUnknownRows = 0,
    this.outWeightUnknownRows = 0,
    this.residualKg,
  });

  final double? openingQty;
  final double? closingQty;
  final double? inQty;
  final double? outQty;

  /// 范围内仓库之间的内部调拨量 (不计入本期收入/发出)。
  final double? internalTransferQty;

  /// 期初/期末结存重量; null = 未知。
  final double? openingWeightKg;
  final double? closingWeightKg;
  final double? inWeightKg;
  final double? outWeightKg;
  final int inWeightUnknownRows;
  final int outWeightUnknownRows;

  /// 本期重量尾差调整合计 (千克)。
  final double? residualKg;

  factory StockLedgerSummary.fromJson(Map<String, dynamic> j) =>
      StockLedgerSummary(
        openingQty: _num(j['openingQty']),
        closingQty: _num(j['closingQty']),
        inQty: _num(j['inQty']),
        outQty: _num(j['outQty']),
        internalTransferQty: _num(j['internalTransferQty']),
        openingWeightKg: _num(j['openingWeightKg']),
        closingWeightKg: _num(j['closingWeightKg']),
        inWeightKg: _num(j['inWeightKg']),
        outWeightKg: _num(j['outWeightKg']),
        inWeightUnknownRows: _int(j['inWeightUnknownRows']) ?? 0,
        outWeightUnknownRows: _int(j['outWeightUnknownRows']) ?? 0,
        residualKg: _num(j['residualKg']),
      );
}

/// 一页流水 + 汇总 + 表头筛选桶 (movementType / warehouse / color)。
class StockLedgerPage {
  const StockLedgerPage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
    this.summary = const StockLedgerSummary(),
    this.facets = const {},
  });

  final List<StockLedgerRow> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;
  final StockLedgerSummary summary;

  /// 表头筛选桶 (服务端给, 每桶 value/label/count; 颜色「无颜色」桶的 value 为 '__null__')。
  final Map<String, List<MasterFacetBucket>> facets;

  factory StockLedgerPage.fromJson(Map<String, dynamic> j) {
    final rawFacets = j['facets'];
    final facets = {
      for (final key in const ['movementType', 'warehouse', 'color'])
        key: parseFacetBuckets(rawFacets, key),
    };
    final summary = j['summary'];
    return StockLedgerPage(
      items: _maps(j['items']).map(StockLedgerRow.fromJson).toList(),
      page: _int(j['page']) ?? 1,
      size: _int(j['size']) ?? 50,
      total: _int(j['total']) ?? 0,
      totalPages: _int(j['totalPages']) ?? 1,
      summary: summary is Map<String, dynamic>
          ? StockLedgerSummary.fromJson(summary)
          : const StockLedgerSummary(),
      facets: facets,
    );
  }
}

/// 单货品 KPI 条 (GET /stock/insights/goods/{goodsId}, stock:view; 不含供应商层面数字)。
class GoodsStockInsight {
  const GoodsStockInsight({
    this.qty,
    this.unitName,
    this.weightKg,
    this.weightEstimated = false,
    this.unitWeightKg,
    this.tier,
    this.relHalfWidth,
    this.lastInAt,
    this.lastOutAt,
    this.avgDailyOut90,
    this.daysOfCover,
    this.abc,
    this.agePct0To30,
  });

  final double? qty;
  final String? unitName;
  final double? weightKg;
  final bool weightEstimated;

  /// 当前单重 (千克/基本单位)。
  final double? unitWeightKg;
  final WeightTier? tier;

  /// 单重 95% 区间相对半宽 (小数, 0.018 = ±1.8%)。
  final double? relHalfWidth;
  final String? lastInAt;
  final String? lastOutAt;
  final double? avgDailyOut90;

  /// 约可用天数; null = 近 90 天没有消耗。
  final double? daysOfCover;

  /// A / B / C / N (N = 近 90 天没有出库)。
  final String? abc;

  /// 30 天内入库的库存占比 (%)。
  final double? agePct0To30;

  factory GoodsStockInsight.fromJson(Map<String, dynamic> j) =>
      GoodsStockInsight(
        qty: _num(j['qty']),
        unitName: _str(j['unitName']),
        weightKg: _num(j['weightKg']),
        weightEstimated: j['weightEstimated'] == true,
        unitWeightKg: _num(j['unitWeightKg']),
        tier: WeightTier.parse(j['tier']?.toString()),
        relHalfWidth: _num(j['relHalfWidth']),
        lastInAt: _str(j['lastInAt']),
        lastOutAt: _str(j['lastOutAt']),
        avgDailyOut90: _num(j['avgDailyOut90']),
        daysOfCover: _num(j['daysOfCover']),
        abc: _str(j['abc']),
        agePct0To30: _num(j['agePct0_30']),
      );
}

/// 流水行的来源单据详情路径; 无来源或未知类型返回 null。
String? stockLedgerSourcePath(StockLedgerRow row) => stockSourceDocPath(
  sourceDocType: row.sourceDocType,
  sourceDocId: row.sourceDocId,
  sourceDocCode: row.sourceDocCode,
);

/// 来源单据详情路径 (按服务端 sourceDocType + sourceDocCode; 仓库单据的 code 即 doc_type)。
/// 流水行与称重记录共用; 无来源或未知类型返回 null。
String? stockSourceDocPath({
  required String? sourceDocType,
  required String? sourceDocId,
  String? sourceDocCode,
}) {
  final id = sourceDocId;
  if (id == null || id.isEmpty) return null;
  final code = sourceDocCode?.trim();
  return switch (sourceDocType) {
    'PURCHASE_RECEIPT' => RoutePath.purchaseDocDetail('receipts', id),
    'PURCHASE_RETURN' => RoutePath.purchaseDocDetail('returns', id),
    'SALES_SHIPMENT' => RoutePath.salesDocDetail('shipments', id),
    'SALES_RETURN' => RoutePath.salesDocDetail('returns', id),
    'SALES_OTHER_SHIPMENT' => RoutePath.salesDocDetail('other-shipments', id),
    'SUBCONTRACT_RECEIPT' => RoutePath.subcontractDocDetail('receipts', id),
    'SUBCONTRACT_RETURN' => RoutePath.subcontractDocDetail('returns', id),
    'SUBCONTRACT_MATERIAL_ISSUE' => RoutePath.subcontractDocDetail(
      'material-issues',
      id,
    ),
    'SUBCONTRACT_MATERIAL_RETURN' => RoutePath.subcontractDocDetail(
      'material-returns',
      id,
    ),
    'SUBCONTRACT_WASTE' => RoutePath.subcontractDocDetail('wastes', id),
    'STOCK_DOC' =>
      (code == null || code.isEmpty)
          ? null
          : RoutePath.stockDocDetail(code.toUpperCase(), id),
    _ => null,
  };
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? v.whereType<Map<String, dynamic>>().toList(growable: false)
    : const [];
