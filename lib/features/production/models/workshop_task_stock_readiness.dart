/// 工单使用的车间内料仓库存提示。所有数量均由服务端按物料基本单位换算；
/// null 表示未知，客户端不把缺单重、未审报工或缺少库存记录当成零。
class WorkshopTaskStockRow {
  const WorkshopTaskStockRow({
    required this.goodsId,
    required this.goodsName,
    required this.status,
    this.colorId,
    this.colorName,
    this.unitName,
    this.bookQty,
    this.warehouseAvailableQty,
    this.estimatedRemainingQty,
    this.requiredQty,
    this.shortageQty,
    this.estimateIncomplete = false,
    this.reason,
  });

  final String goodsId;
  final String goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitName;
  final double? bookQty;
  final double? warehouseAvailableQty;
  final double? estimatedRemainingQty;
  final double? requiredQty;
  final double? shortageQty;
  final String status;
  final bool estimateIncomplete;
  final String? reason;

  String get label => [goodsName, ?colorName].join(' ');

  factory WorkshopTaskStockRow.fromJson(Map<String, dynamic> json) =>
      WorkshopTaskStockRow(
        goodsId: json['goodsId'] as String? ?? '',
        goodsName: json['goodsName'] as String? ?? '未命名的料',
        colorId: json['colorId'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        bookQty: _number(json['bookQty']),
        warehouseAvailableQty: _number(json['warehouseAvailableQty']),
        estimatedRemainingQty: _number(json['estimatedRemainingQty']),
        requiredQty: _number(json['requiredQty']),
        shortageQty: _number(json['shortageQty']),
        status: json['status'] as String? ?? 'UNKNOWN',
        estimateIncomplete: json['estimateIncomplete'] == true,
        reason: json['reason'] as String?,
      );
}

class WorkshopTaskStockReadiness {
  const WorkshopTaskStockReadiness({
    required this.workshopDepartmentId,
    required this.workshopName,
    required this.rows,
    this.binWarehouseId,
    this.estimateIncomplete = false,
    this.reason,
    this.allowedActions = const [],
  });

  final String workshopDepartmentId;
  final String workshopName;
  final String? binWarehouseId;
  final List<WorkshopTaskStockRow> rows;
  final bool estimateIncomplete;
  final String? reason;
  final List<String> allowedActions;

  bool get canRequest => allowedActions.contains('REQUEST');

  factory WorkshopTaskStockReadiness.fromJson(Map<String, dynamic> json) =>
      WorkshopTaskStockReadiness(
        workshopDepartmentId: json['workshopDepartmentId'] as String? ?? '',
        workshopName: json['workshopName'] as String? ?? '',
        binWarehouseId: json['binWarehouseId'] as String?,
        rows: [
          for (final row in json['rows'] as List? ?? const [])
            if (row is Map)
              WorkshopTaskStockRow.fromJson(Map<String, dynamic>.from(row)),
        ],
        estimateIncomplete: json['estimateIncomplete'] == true,
        reason: json['reason'] as String?,
        allowedActions: (json['allowedActions'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
      );
}

double? _number(Object? value) => value is num
    ? value.toDouble()
    : value is String
    ? double.tryParse(value)
    : null;
