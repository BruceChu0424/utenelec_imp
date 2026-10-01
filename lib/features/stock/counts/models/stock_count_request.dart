import '../../../../shared/formatters/exact_decimal.dart';

const stockCountSubmitPermission = 'stock:count:submit';
const stockCountFinanceReviewPermission = 'stock:count:finance_review';
const stockCountWarehouseReviewPermission = 'stock:count:warehouse_review';

String stockCountRowKey(String goodsId, String? colorId) =>
    '$goodsId|${colorId ?? ''}';
String? _decimal(Object? value) => financeExactDecimal(value);
List<Map<String, dynamic>> _rows(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map) Map<String, dynamic>.from(row),
];
List<String> _actions(Object? value) =>
    value is List ? value.whereType<String>().toList() : const [];

class StockCountWarehouse {
  const StockCountWarehouse({
    required this.id,
    required this.name,
    required this.kind,
    required this.reviewRoute,
  });
  final String id;
  final String name;
  final String kind;
  final String reviewRoute;
  bool get isWorkshop => kind == 'WORKSHOP';
  String get reviewerLabel => reviewRoute == 'WAREHOUSE' ? '仓库' : '财务';
  factory StockCountWarehouse.fromJson(Map<String, dynamic> json) =>
      StockCountWarehouse(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? 'NORMAL',
        reviewRoute: json['reviewRoute'] as String? ?? 'FINANCE',
      );
}

class StockCountScope {
  const StockCountScope({
    required this.warehouses,
    this.allowedActions = const [],
  });
  final List<StockCountWarehouse> warehouses;
  final List<String> allowedActions;
  bool get canSubmit => allowedActions.contains('SUBMIT');
  factory StockCountScope.fromJson(Map<String, dynamic> json) =>
      StockCountScope(
        warehouses: _rows(
          json['warehouses'],
        ).map(StockCountWarehouse.fromJson).toList(),
        allowedActions: _actions(json['allowedActions']),
      );
}

/// A precise single-warehouse snapshot. Never substitute an aggregate inventory row.
class CountStockRow {
  const CountStockRow({
    required this.goodsId,
    required this.goodsName,
    required this.unitId,
    required this.unitName,
    required this.qty,
    required this.goodsVersion,
    this.goodsCode = '',
    this.colorId,
    this.colorName,
    this.weightKg,
    this.weightEstimated = false,
    this.kgPerBaseUnit,
    this.issueMethod = 'ORDER',
    this.allowedActions = const [],
  });
  final String goodsId;
  final String goodsCode;
  final String goodsName;
  final String? colorId;
  final String? colorName;
  final String unitId;
  final String unitName;
  final String qty;
  final String? weightKg;
  final bool weightEstimated;
  final String? kgPerBaseUnit;
  final int goodsVersion;
  final String issueMethod;
  final List<String> allowedActions;
  String get key => stockCountRowKey(goodsId, colorId);
  bool get canEdit => allowedActions.contains('EDIT');
  bool get weightExact => kgPerBaseUnit != null;
  factory CountStockRow.fromJson(Map<String, dynamic> json) => CountStockRow(
    goodsId: json['goodsId'] as String,
    goodsCode: json['goodsCode'] as String? ?? '',
    goodsName: json['goodsName'] as String? ?? '',
    colorId: json['colorId'] as String?,
    colorName: json['colorName'] as String?,
    unitId: json['unitId'] as String,
    unitName: json['unitName'] as String? ?? '',
    qty: _decimal(json['qty']) ?? (throw const FormatException('盘点快照缺少数量')),
    weightKg: _decimal(json['weightKg']),
    weightEstimated: json['weightEstimated'] == true,
    kgPerBaseUnit: _decimal(json['kgPerBaseUnit']),
    goodsVersion: (json['goodsVersion'] as num).toInt(),
    issueMethod: json['issueMethod'] as String? ?? 'ORDER',
    allowedActions: _actions(json['allowedActions']),
  );
}

class StockCountRequestLine {
  const StockCountRequestLine({
    required this.goodsId,
    required this.goodsName,
    this.goodsCode = '',
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName = '',
    this.beforeQty,
    this.beforeWeightKg,
    this.targetQty,
    this.targetWeightKg,
    this.weightChanged = false,
    this.deltaQty,
    this.deltaWeightKg,
    this.currentQty,
    this.currentWeightKg,
    this.stale = false,
    this.materialSetupBasis,
    this.goodsVersion = 0,
    this.weightEstimated = false,
    this.kgPerBaseUnit,
    this.issueMethod,
  });
  final String goodsId;
  final String goodsCode;
  final String goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String unitName;
  final String? beforeQty;
  final String? beforeWeightKg;
  final String? targetQty;
  final String? targetWeightKg;
  final bool weightChanged;
  final String? deltaQty;
  final String? deltaWeightKg;
  final String? currentQty;
  final String? currentWeightKg;
  final bool stale;
  final String? materialSetupBasis;
  final int goodsVersion;
  final bool weightEstimated;
  final String? kgPerBaseUnit;
  final String? issueMethod;
  String get key => stockCountRowKey(goodsId, colorId);
  factory StockCountRequestLine.fromJson(Map<String, dynamic> json) =>
      StockCountRequestLine(
        goodsId: json['goodsId'] as String,
        goodsName: json['goodsName'] as String? ?? '',
        goodsCode: json['goodsCode'] as String? ?? '',
        colorId: json['colorId'] as String?,
        colorName: json['colorName'] as String?,
        unitId: json['unitId'] as String?,
        unitName: json['unitName'] as String? ?? '',
        beforeQty: _decimal(json['beforeQty']),
        beforeWeightKg: _decimal(json['beforeWeightKg']),
        targetQty: _decimal(json['targetQty']),
        targetWeightKg: _decimal(json['targetWeightKg']),
        weightChanged: json['weightChanged'] == true,
        deltaQty: _decimal(json['deltaQty']),
        deltaWeightKg: _decimal(json['deltaWeightKg']),
        currentQty: _decimal(json['currentQty']),
        currentWeightKg: _decimal(json['currentWeightKg']),
        stale: json['stale'] == true,
        materialSetupBasis: json['materialSetupBasis'] as String?,
        goodsVersion: (json['goodsVersion'] as num?)?.toInt() ?? 0,
        weightEstimated: json['weightEstimated'] == true,
        kgPerBaseUnit: _decimal(json['kgPerBaseUnit']),
        issueMethod: json['issueMethod'] as String?,
      );
}

class StockCountRequest {
  const StockCountRequest({
    required this.id,
    required this.requestNo,
    required this.warehouseId,
    required this.warehouseName,
    required this.reviewRoute,
    required this.status,
    required this.version,
    this.submittedByName,
    this.submittedAt,
    this.reason,
    this.reviewReason,
    this.stockDocumentId,
    this.lines = const [],
    this.allowedActions = const [],
  });
  final String id;
  final String requestNo;
  final String warehouseId;
  final String warehouseName;
  final String reviewRoute;
  final String status;
  final int version;
  final String? submittedByName;
  final String? submittedAt;
  final String? reason;
  final String? reviewReason;
  final String? stockDocumentId;
  final List<StockCountRequestLine> lines;
  final List<String> allowedActions;
  bool get canApprove => allowedActions.contains('APPROVE');
  bool get canReject => allowedActions.contains('REJECT');
  bool get canCancel => allowedActions.contains('CANCEL');
  factory StockCountRequest.fromJson(Map<String, dynamic> json) =>
      StockCountRequest(
        id: json['id'] as String,
        requestNo: json['requestNo'] as String? ?? '',
        warehouseId: json['warehouseId'] as String? ?? '',
        warehouseName: json['warehouseName'] as String? ?? '',
        reviewRoute: json['reviewRoute'] as String? ?? '',
        status: json['status'] as String? ?? '',
        version: (json['version'] as num?)?.toInt() ?? 0,
        submittedByName: json['submittedByName'] as String?,
        submittedAt: json['submittedAt'] as String?,
        reason: json['reason'] as String?,
        reviewReason: json['reviewReason'] as String?,
        stockDocumentId: json['stockDocumentId'] as String?,
        lines: _rows(
          json['lines'],
        ).map(StockCountRequestLine.fromJson).toList(),
        allowedActions: _actions(json['allowedActions']),
      );
}

class StockCountCounts {
  const StockCountCounts({
    this.financePending = 0,
    this.warehousePending = 0,
    this.myPending = 0,
    this.myRejected = 0,
  });
  final int financePending;
  final int warehousePending;
  final int myPending;
  final int myRejected;
  factory StockCountCounts.fromJson(Map<String, dynamic> json) =>
      StockCountCounts(
        financePending: (json['financePending'] as num?)?.toInt() ?? 0,
        warehousePending: (json['warehousePending'] as num?)?.toInt() ?? 0,
        myPending: (json['myPending'] as num?)?.toInt() ?? 0,
        myRejected: (json['myRejected'] as num?)?.toInt() ?? 0,
      );
}
