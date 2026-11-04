import '../formatters/exact_decimal.dart';

enum WarehouseInboundAllocationKind {
  // 2026-09-27 用户口径：登记实际到货的「预计去向」汇总用业务语言——
  // EXACT_ANALYSIS 显示「计划部预定」，PUBLIC 显示「仓库存放」。
  exactAnalysis('EXACT_ANALYSIS', '计划部预定'),
  sharedClaim('SHARED_CLAIM', '公共在途已采用'),
  formalDemand('FORMAL_DEMAND', '正式工单'),
  publicStock('PUBLIC', '仓库存放'),
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
    this.qtyExact,
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
  final String? qtyExact;
  String? get quantityText => financeExactDecimal(qtyExact ?? qty);
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

  WarehouseInboundAllocation copyWithQty(Object value) => _copyAllocation(
    this,
    qty: double.tryParse(value.toString()),
    qtyExact: financeExactDecimal(value),
  );

  factory WarehouseInboundAllocation.fromJson(Map<String, dynamic> json) =>
      WarehouseInboundAllocation(
        passEventId: _text(json['passEventId']),
        stockInBatchItemId: _text(json['stockInBatchItemId']),
        kind: WarehouseInboundAllocationKind.from(json['kind']),
        qty: _decimal(json['qtyExact'] ?? json['qty']),
        qtyExact: financeExactDecimal(json['qtyExact'] ?? json['qty']),
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

BigInt? warehouseInboundQuantityUnits(Object? value) =>
    financeExactDecimalUnits(
      financeExactTrimmed(financeExactDecimal(value)),
      scale: 24,
    );
String warehouseInboundQuantityText(BigInt units) =>
    financeExactTrimmed(financeExactDecimalFromUnits(units, scale: 24))!;

List<WarehouseInboundAllocation> warehouseInboundAllocationPreview(
  Iterable<WarehouseInboundAllocation> allocations,
  Object requestedQty,
) {
  final requested = warehouseInboundQuantityUnits(requestedQty);
  if (requested == null || requested <= BigInt.zero) return const [];
  final source = allocations.toList(growable: false);
  var remaining = requested;
  final result = <WarehouseInboundAllocation>[];
  for (final allocation in source) {
    if (remaining <= BigInt.zero) break;
    final capacity = warehouseInboundQuantityUnits(allocation.quantityText);
    if (capacity == null) break;
    if (capacity <= BigInt.zero) continue;
    final take = capacity < remaining ? capacity : remaining;
    result.add(allocation.copyWithQty(warehouseInboundQuantityText(take)));
    remaining -= take;
  }
  if (source.isNotEmpty && remaining > BigInt.zero) {
    final context = source.first;
    result.add(
      WarehouseInboundAllocation(
        passEventId: context.passEventId,
        kind: WarehouseInboundAllocationKind.unknown,
        qty: double.parse(warehouseInboundQuantityText(remaining)),
        qtyExact: warehouseInboundQuantityText(remaining),
        actualWarehouseId: context.actualWarehouseId,
        actualWarehouseName: context.actualWarehouseName,
        baseUnitName: context.baseUnitName,
        formationStatus: '预计去向合计小于本次实收，差额去向待服务端复核',
      ),
    );
  }
  return List.unmodifiable(result);
}

/// Same warehouse/ownership rules as the authoritative source; decimal text
/// keeps every source digit. No epsilon, implicit unit rate, or rounded slices.
List<WarehouseInboundAllocation> warehouseInboundAllocationForWarehouse(
  Iterable<WarehouseInboundAllocation> allocations,
  Object requestedDisplayQty, {
  required String? actualWarehouseId,
  String? actualWarehouseName,
  bool Function(String? targetWarehouseId, String actualWarehouseId)?
  sameMainWarehouse,
  Object unitRate = 1,
}) {
  final requested = warehouseInboundQuantityUnits(
    financeExactMultiplyTexts([
      financeExactDecimal(requestedDisplayQty),
      financeExactDecimal(unitRate),
    ]),
  );
  if (requested == null || requested <= BigInt.zero) return const [];
  final source = allocations
      .where(
        (item) =>
            (warehouseInboundQuantityUnits(item.quantityText) ?? BigInt.zero) >
            BigInt.zero,
      )
      .toList(growable: false);
  if (source.isEmpty) return const [];
  if (actualWarehouseId == null || actualWarehouseId.trim().isEmpty) {
    final neutral = [
      for (final item in source) _copyAllocation(item, warehouseMatches: true),
    ];
    return warehouseInboundAllocationPreview(
      neutral,
      warehouseInboundQuantityText(requested),
    );
  }
  final selectedId = actualWarehouseId.trim();
  var remaining = requested;
  final result = <WarehouseInboundAllocation>[];
  final targeted = source
      .where((item) => !item.isPublic)
      .toList(growable: false);
  bool matches(WarehouseInboundAllocation item) =>
      item.targetWarehouseId == selectedId ||
      (item.kind != WarehouseInboundAllocationKind.formalDemand &&
          sameMainWarehouse?.call(item.targetWarehouseId, selectedId) == true);
  void take(
    WarehouseInboundAllocation allocation, {
    bool mismatch = false,
    bool public = false,
  }) {
    if (remaining <= BigInt.zero) return;
    final capacity = warehouseInboundQuantityUnits(allocation.quantityText)!;
    final taken = capacity < remaining ? capacity : remaining;
    final text = warehouseInboundQuantityText(taken);
    result.add(
      _copyAllocation(
        allocation,
        qty: double.parse(text),
        qtyExact: text,
        kind: mismatch ? WarehouseInboundAllocationKind.publicStock : null,
        actualWarehouseId: selectedId,
        actualWarehouseName: actualWarehouseName,
        intendedWarehouseNames: mismatch
            ? <String>{
                ...allocation.intendedWarehouseNames,
                ?allocation.targetWarehouseName,
              }.where((v) => v.isNotEmpty).toList(growable: false)
            : public
            ? const []
            : null,
        warehouseMatches: !mismatch,
        formationStatus: mismatch
            ? '原预定因所选实际仓不符，本部分预计不绑定计划，按实际仓公共入库'
            : public
            ? '未被生产需求预定；预计按所选实际仓进入公共库存'
            : null,
      ),
    );
    remaining -= taken;
  }

  for (final allocation in targeted.where(matches)) {
    take(allocation);
  }
  for (final allocation in targeted.where((item) => !matches(item))) {
    take(allocation, mismatch: true);
  }
  final publicSource = source
      .where((item) => item.isPublic)
      .toList(growable: false);
  if (publicSource.isNotEmpty && remaining > BigInt.zero) {
    final capacity = publicSource.fold(
      BigInt.zero,
      (sum, item) => sum + warehouseInboundQuantityUnits(item.quantityText)!,
    );
    final merged = _copyAllocation(
      publicSource.first,
      qty: double.parse(warehouseInboundQuantityText(capacity)),
      qtyExact: warehouseInboundQuantityText(capacity),
      baseUnitName: source
          .map((item) => item.baseUnitName)
          .whereType<String>()
          .firstOrNull,
    );
    take(merged, public: true);
  }
  if (remaining > BigInt.zero) {
    final text = warehouseInboundQuantityText(remaining);
    result.add(
      WarehouseInboundAllocation(
        kind: WarehouseInboundAllocationKind.unknown,
        qty: double.parse(text),
        qtyExact: text,
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
  String? qtyExact,
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
  qtyExact:
      qtyExact ?? (qty == null ? value.qtyExact : financeExactDecimal(qty)),
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
