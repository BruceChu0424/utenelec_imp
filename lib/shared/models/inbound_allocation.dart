enum WarehouseInboundAllocationKind {
  exactAnalysis('EXACT_ANALYSIS', '本分析预定'),
  sharedClaim('SHARED_CLAIM', '公共在途已采用'),
  formalDemand('FORMAL_DEMAND', '正式工单'),
  publicStock('PUBLIC', '公共库存'),
  unknown('UNKNOWN', '去向待确认');

  const WarehouseInboundAllocationKind(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static WarehouseInboundAllocationKind from(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    return values.firstWhere(
      (kind) => kind.apiValue == normalized,
      orElse: () => unknown,
    );
  }
}

/// Amount-free expected or committed purpose of one inbound stock slice.
/// Missing fields are intentionally tolerated for old server responses.
class WarehouseInboundAllocation {
  const WarehouseInboundAllocation({
    required this.kind,
    required this.qty,
    this.passEventId,
    this.stockInBatchItemId,
    this.actualWarehouseId,
    this.actualWarehouseName,
    this.targetWarehouseId,
    this.targetWarehouseName,
    this.intendedWarehouseNames = const [],
    this.warehouseMatches = true,
    this.analysisId,
    this.analysisMaterialId,
    this.productCode,
    this.productName,
    this.baseUnitName,
    this.sourceLabel,
    this.planId,
    this.planNo,
    this.executionSegmentId,
    this.executionSegmentCode,
    this.workshopDepartmentId,
    this.workshopName,
    this.responsibleEmployeeId,
    this.responsibleEmployeeName,
    this.formationStatus,
  });

  final String? passEventId;
  final String? stockInBatchItemId;
  final WarehouseInboundAllocationKind kind;
  final double qty;
  final String? actualWarehouseId;
  final String? actualWarehouseName;
  final String? targetWarehouseId;
  final String? targetWarehouseName;
  final List<String> intendedWarehouseNames;
  final bool warehouseMatches;
  final String? analysisId;
  final String? analysisMaterialId;
  final String? productCode;
  final String? productName;
  final String? baseUnitName;
  final String? sourceLabel;
  final String? planId;
  final String? planNo;
  final String? executionSegmentId;
  final String? executionSegmentCode;
  final String? workshopDepartmentId;
  final String? workshopName;
  final String? responsibleEmployeeId;
  final String? responsibleEmployeeName;
  final String? formationStatus;

  bool get isPublic => kind == WarehouseInboundAllocationKind.publicStock;
  bool get isCrossWarehouse => !warehouseMatches;
  bool get hasFormalWorkOrder =>
      kind == WarehouseInboundAllocationKind.formalDemand &&
      executionSegmentId?.isNotEmpty == true;

  String get productLabel => [
    productCode,
    productName,
  ].where((value) => value?.trim().isNotEmpty == true).join(' · ');

  WarehouseInboundAllocation copyWithQty(double value) =>
      _copyAllocation(this, qty: value);

  factory WarehouseInboundAllocation.fromJson(Map<String, dynamic> json) =>
      WarehouseInboundAllocation(
        passEventId: _text(json['passEventId']),
        stockInBatchItemId: _text(json['stockInBatchItemId']),
        kind: WarehouseInboundAllocationKind.from(json['kind']),
        qty: _decimal(json['qty']),
        actualWarehouseId: _text(json['actualWarehouseId']),
        actualWarehouseName: _text(json['actualWarehouseName']),
        targetWarehouseId: _text(json['targetWarehouseId']),
        targetWarehouseName: _text(json['targetWarehouseName']),
        intendedWarehouseNames: _stringList(json['intendedWarehouseNames']),
        warehouseMatches: json['warehouseMatches'] != false,
        analysisId: _text(json['analysisId']),
        analysisMaterialId: _text(json['analysisMaterialId']),
        productCode: _text(json['productCode']),
        productName: _text(json['productName']),
        baseUnitName: _text(json['baseUnitName']),
        sourceLabel: _text(json['sourceLabel']),
        planId: _text(json['planId']),
        planNo: _text(json['planNo']),
        executionSegmentId: _text(json['executionSegmentId']),
        executionSegmentCode: _text(json['executionSegmentCode']),
        workshopDepartmentId: _text(json['workshopDepartmentId']),
        workshopName: _text(json['workshopName']),
        responsibleEmployeeId: _text(json['responsibleEmployeeId']),
        responsibleEmployeeName: _text(json['responsibleEmployeeName']),
        formationStatus: _text(json['formationStatus']),
      );
}

List<WarehouseInboundAllocation> warehouseInboundAllocationPreview(
  Iterable<WarehouseInboundAllocation> allocations,
  double requestedQty,
) {
  if (!requestedQty.isFinite || requestedQty <= 0) return const [];
  final source = allocations.toList(growable: false);
  var remaining = requestedQty;
  final result = <WarehouseInboundAllocation>[];
  for (final allocation in source) {
    if (remaining <= 0) break;
    if (!allocation.qty.isFinite || allocation.qty <= 0) continue;
    final take = allocation.qty < remaining ? allocation.qty : remaining;
    result.add(allocation.copyWithQty(take));
    remaining -= take;
  }
  if (source.isNotEmpty && remaining > 0.0000001) {
    final context = source.first;
    result.add(
      WarehouseInboundAllocation(
        passEventId: context.passEventId,
        kind: WarehouseInboundAllocationKind.unknown,
        qty: remaining,
        actualWarehouseId: context.actualWarehouseId,
        actualWarehouseName: context.actualWarehouseName,
        baseUnitName: context.baseUnitName,
        formationStatus: '预计去向合计小于本次实收，差额去向待服务端复核',
      ),
    );
  }
  return List.unmodifiable(result);
}

/// Reprojects order-item allocations for the warehouse selected on the arrival
/// form. Server and returned allocation quantities remain base-unit values;
/// only the row input is converted through [unitRate].
List<WarehouseInboundAllocation> warehouseInboundAllocationForWarehouse(
  Iterable<WarehouseInboundAllocation> allocations,
  double requestedDisplayQty, {
  required String? actualWarehouseId,
  String? actualWarehouseName,
  double unitRate = 1,
}) {
  if (!requestedDisplayQty.isFinite || requestedDisplayQty <= 0) {
    return const [];
  }
  final rate = unitRate.isFinite && unitRate > 0 ? unitRate : 1.0;
  final requestedBaseQty = requestedDisplayQty * rate;
  final source = allocations
      .where((item) => item.qty.isFinite && item.qty > 0)
      .toList(growable: false);
  if (source.isEmpty) return const [];

  if (actualWarehouseId == null || actualWarehouseId.trim().isEmpty) {
    final neutral = [
      for (final item in source) _copyAllocation(item, warehouseMatches: true),
    ];
    return warehouseInboundAllocationPreview(neutral, requestedBaseQty);
  }

  final selectedId = actualWarehouseId.trim();
  var remaining = requestedBaseQty;
  final result = <WarehouseInboundAllocation>[];
  final targeted = source
      .where((item) => !item.isPublic)
      .toList(growable: false);
  final matching = targeted
      .where((item) => item.targetWarehouseId == selectedId)
      .toList(growable: false);
  for (final allocation in matching) {
    if (remaining <= 0) break;
    final take = allocation.qty < remaining ? allocation.qty : remaining;
    result.add(
      _copyAllocation(
        allocation,
        qty: take,
        actualWarehouseId: selectedId,
        actualWarehouseName: actualWarehouseName,
        warehouseMatches: true,
      ),
    );
    remaining -= take;
  }

  final mismatched = targeted
      .where((item) => item.targetWarehouseId != selectedId)
      .toList(growable: false);
  for (final allocation in mismatched) {
    if (remaining <= 0) break;
    final take = allocation.qty < remaining ? allocation.qty : remaining;
    final intended = <String>{
      ...allocation.intendedWarehouseNames,
      ?allocation.targetWarehouseName,
    }.where((name) => name.isNotEmpty).toList(growable: false);
    result.add(
      _copyAllocation(
        allocation,
        kind: WarehouseInboundAllocationKind.publicStock,
        qty: take,
        actualWarehouseId: selectedId,
        actualWarehouseName: actualWarehouseName,
        intendedWarehouseNames: intended,
        warehouseMatches: false,
        formationStatus: '原预定因所选实际仓不符，本部分预计不绑定计划，按实际仓公共入库',
      ),
    );
    remaining -= take;
  }

  final publicSource = source
      .where((item) => item.isPublic)
      .toList(growable: false);
  final publicCapacity = publicSource.fold<double>(
    0,
    (sum, item) => sum + item.qty,
  );
  if (remaining > 0 && publicCapacity > 0) {
    final take = publicCapacity < remaining ? publicCapacity : remaining;
    final context = publicSource.first;
    result.add(
      _copyAllocation(
        context,
        qty: take,
        actualWarehouseId: selectedId,
        actualWarehouseName: actualWarehouseName,
        baseUnitName: source
            .map((item) => item.baseUnitName)
            .whereType<String>()
            .firstOrNull,
        intendedWarehouseNames: const [],
        warehouseMatches: true,
        formationStatus: '未被生产需求预定；预计按所选实际仓进入公共库存',
      ),
    );
    remaining -= take;
  }

  if (remaining > 0.0000001) {
    result.add(
      WarehouseInboundAllocation(
        kind: WarehouseInboundAllocationKind.unknown,
        qty: remaining,
        actualWarehouseId: selectedId,
        actualWarehouseName: actualWarehouseName,
        formationStatus: '预计去向合计小于本次实收，差额去向待服务端复核',
      ),
    );
  }
  return List.unmodifiable(result);
}

WarehouseInboundAllocation _copyAllocation(
  WarehouseInboundAllocation value, {
  WarehouseInboundAllocationKind? kind,
  double? qty,
  String? actualWarehouseId,
  String? actualWarehouseName,
  String? baseUnitName,
  List<String>? intendedWarehouseNames,
  bool? warehouseMatches,
  String? formationStatus,
}) => WarehouseInboundAllocation(
  passEventId: value.passEventId,
  stockInBatchItemId: value.stockInBatchItemId,
  kind: kind ?? value.kind,
  qty: qty ?? value.qty,
  actualWarehouseId: actualWarehouseId ?? value.actualWarehouseId,
  actualWarehouseName: actualWarehouseName ?? value.actualWarehouseName,
  targetWarehouseId: value.targetWarehouseId,
  targetWarehouseName: value.targetWarehouseName,
  intendedWarehouseNames:
      intendedWarehouseNames ?? value.intendedWarehouseNames,
  warehouseMatches: warehouseMatches ?? value.warehouseMatches,
  analysisId: value.analysisId,
  analysisMaterialId: value.analysisMaterialId,
  productCode: value.productCode,
  productName: value.productName,
  baseUnitName: baseUnitName ?? value.baseUnitName,
  sourceLabel: value.sourceLabel,
  planId: value.planId,
  planNo: value.planNo,
  executionSegmentId: value.executionSegmentId,
  executionSegmentCode: value.executionSegmentCode,
  workshopDepartmentId: value.workshopDepartmentId,
  workshopName: value.workshopName,
  responsibleEmployeeId: value.responsibleEmployeeId,
  responsibleEmployeeName: value.responsibleEmployeeName,
  formationStatus: formationStatus ?? value.formationStatus,
);

String? _text(Object? value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

double _decimal(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

List<String> _stringList(Object? value) =>
    value is List ? [for (final item in value) ?_text(item)] : const [];
