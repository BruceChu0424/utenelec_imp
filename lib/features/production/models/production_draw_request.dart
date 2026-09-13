/// A workshop segment and the version the operator has reviewed.
/// Preview permits a missing version for a direct link; submit always uses the
/// authoritative versions returned in [ProductionDrawRequestPreview.tasks].
class ProductionDrawRequestItem {
  const ProductionDrawRequestItem({
    required this.segmentId,
    this.expectedVersion,
  });

  final String segmentId;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => {
    'segmentId': segmentId,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
  };
}

/// An exact, reviewed source line and this request's quantity in its DRAW unit.
class ProductionDrawRequestSelection {
  const ProductionDrawRequestSelection({
    required this.drawItemId,
    required this.quantity,
  });

  final String drawItemId;
  final double quantity;

  Map<String, dynamic> toJson() => {
    'drawItemId': drawItemId,
    'quantity': quantity,
  };
}

class ProductionDrawRequestTask {
  const ProductionDrawRequestTask({
    required this.segmentId,
    required this.expectedVersion,
    this.planId,
    this.planNo,
    this.segmentCode,
    this.workshopDepartmentId,
    this.workshopName,
    this.productCode,
    this.productName,
    this.plannedQty = 0,
  });

  final String segmentId;
  final int expectedVersion;
  final String? planId;
  final String? planNo;
  final String? segmentCode;
  final String? workshopDepartmentId;
  final String? workshopName;
  final String? productCode;
  final String? productName;
  final double plannedQty;

  factory ProductionDrawRequestTask.fromJson(Map<String, dynamic> json) =>
      ProductionDrawRequestTask(
        segmentId: json['segmentId'] as String,
        expectedVersion: (json['expectedVersion'] as num).toInt(),
        planId: json['planId'] as String?,
        planNo: json['planNo'] as String?,
        segmentCode: json['segmentCode'] as String?,
        workshopDepartmentId: json['workshopDepartmentId'] as String?,
        workshopName: json['workshopName'] as String?,
        productCode: json['productCode'] as String?,
        productName: json['productName'] as String?,
        plannedQty: (json['plannedQty'] as num?)?.toDouble() ?? 0,
      );

  ProductionDrawRequestItem get requestItem => ProductionDrawRequestItem(
    segmentId: segmentId,
    expectedVersion: expectedVersion,
  );
}

/// Server aggregation uses actual warehouse, goods, color and unit UUIDs.
/// Names and codes are display data and must never be used for matching lines.
class ProductionDrawRequestSummary {
  const ProductionDrawRequestSummary({
    required this.warehouseId,
    required this.goodsId,
    required this.qty,
    this.warehouseName,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
  });

  final String warehouseId;
  final String goodsId;
  final String? warehouseName;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double qty;

  String get identity =>
      '$warehouseId|$goodsId|${colorId ?? ''}|${unitId ?? ''}';

  factory ProductionDrawRequestSummary.fromJson(Map<String, dynamic> json) =>
      ProductionDrawRequestSummary(
        warehouseId: json['warehouseId'] as String,
        goodsId: json['goodsId'] as String,
        warehouseName: json['warehouseName'] as String?,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorId: json['colorId'] as String?,
        colorName: json['colorName'] as String?,
        unitId: json['unitId'] as String?,
        unitName: json['unitName'] as String?,
        qty: (json['qty'] as num).toDouble(),
      );

  bool matches(ProductionDrawRequestLine line) =>
      warehouseId == line.warehouseId &&
      goodsId == line.goodsId &&
      colorId == line.colorId &&
      unitId == line.unitId;
}

class ProductionDrawRequestLine extends ProductionDrawRequestSummary {
  const ProductionDrawRequestLine({
    required this.segmentId,
    required this.drawId,
    required this.drawItemId,
    this.drawNo,
    required super.warehouseId,
    required super.goodsId,
    required super.qty,
    super.warehouseName,
    super.goodsCode,
    super.goodsName,
    super.colorId,
    super.colorName,
    super.unitId,
    super.unitName,
  });

  final String segmentId;
  final String drawId;
  final String drawItemId;
  final String? drawNo;

  factory ProductionDrawRequestLine.fromJson(Map<String, dynamic> json) =>
      ProductionDrawRequestLine(
        segmentId: json['segmentId'] as String,
        drawId: json['drawId'] as String,
        drawItemId: json['drawItemId'] as String,
        drawNo: json['drawNo'] as String?,
        warehouseId: json['warehouseId'] as String,
        warehouseName: json['warehouseName'] as String?,
        goodsId: json['goodsId'] as String,
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorId: json['colorId'] as String?,
        colorName: json['colorName'] as String?,
        unitId: json['unitId'] as String?,
        unitName: json['unitName'] as String?,
        qty: (json['qty'] as num).toDouble(),
      );
}

class ProductionDrawRequestPreview {
  const ProductionDrawRequestPreview({
    required this.fingerprint,
    required this.taskCount,
    required this.documentCount,
    required this.lineCount,
    required this.tasks,
    required this.lines,
    required this.summaries,
  });

  final String fingerprint;
  final int taskCount;
  final int documentCount;
  final int lineCount;
  final List<ProductionDrawRequestTask> tasks;
  final List<ProductionDrawRequestLine> lines;
  final List<ProductionDrawRequestSummary> summaries;

  factory ProductionDrawRequestPreview.fromJson(Map<String, dynamic> json) =>
      ProductionDrawRequestPreview(
        fingerprint: json['fingerprint'] as String,
        taskCount: (json['taskCount'] as num).toInt(),
        documentCount: (json['documentCount'] as num).toInt(),
        lineCount: (json['lineCount'] as num).toInt(),
        tasks: _rows(json['tasks'], ProductionDrawRequestTask.fromJson),
        lines: _rows(json['lines'], ProductionDrawRequestLine.fromJson),
        summaries: _rows(
          json['summaries'],
          ProductionDrawRequestSummary.fromJson,
        ),
      );

  List<ProductionDrawRequestItem> get requestItems => [
    for (final task in tasks) task.requestItem,
  ];

  List<ProductionDrawRequestLine> sourcesFor(
    ProductionDrawRequestSummary summary,
  ) => lines.where(summary.matches).toList(growable: false);

  ProductionDrawRequestTask? taskFor(String segmentId) =>
      tasks.where((task) => task.segmentId == segmentId).firstOrNull;

  /// Resolve an edited summary to original UUIDs, never to names or new demand.
  /// Stable ordering makes the displayed source split and retries identical.
  List<ProductionDrawRequestSelection> selectionsFor(
    ProductionDrawRequestSummary summary,
    double quantity,
  ) {
    if (!quantity.isFinite ||
        quantity <= 0 ||
        quantity > summary.qty + 0.000001) {
      throw const FormatException('本次领料数量必须大于 0 且不超过待申请量');
    }
    final sources = sourcesFor(summary)
      ..sort((a, b) => a.drawItemId.compareTo(b.drawItemId));
    var remaining = quantity;
    final selections = <ProductionDrawRequestSelection>[];
    for (final source in sources) {
      if (remaining <= 0.000001) break;
      final allocated = remaining < source.qty ? remaining : source.qty;
      if (allocated <= 0) continue;
      selections.add(
        ProductionDrawRequestSelection(
          drawItemId: source.drawItemId,
          quantity: double.parse(allocated.toStringAsFixed(4)),
        ),
      );
      remaining -= allocated;
    }
    if (remaining > 0.000001) {
      throw const FormatException('物料来源数量已变化，请刷新领料汇总');
    }
    return selections;
  }
}

class ProductionDrawRequestResult {
  const ProductionDrawRequestResult({
    required this.segmentIds,
    required this.documentIds,
    required this.taskCount,
    required this.documentCount,
    required this.replayed,
  });

  final List<String> segmentIds;
  final List<String> documentIds;
  final int taskCount;
  final int documentCount;
  final bool replayed;

  factory ProductionDrawRequestResult.fromJson(Map<String, dynamic> json) =>
      ProductionDrawRequestResult(
        segmentIds: (json['segmentIds'] as List).cast<String>(),
        documentIds: (json['documentIds'] as List).cast<String>(),
        taskCount: (json['taskCount'] as num).toInt(),
        documentCount: (json['documentCount'] as num).toInt(),
        replayed: json['replayed'] == true,
      );
}

List<T> _rows<T>(Object? value, T Function(Map<String, dynamic>) parse) =>
    (value as List? ?? const [])
        .map((row) => parse(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
