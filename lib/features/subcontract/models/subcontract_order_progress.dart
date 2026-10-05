// 委外订货单全链路进度模型(ADR-143 §4.6)。
// 对应 GET /api/subcontract/orders/{id}/progress。
//
// 一条订货明细 = 一个委外任务，一条时间线：下单 → 财务审批 → 领料发外(已领 x/Q) →
// 加工回厂 → 品质检验 → 仓库确认入仓 → 结案核销。节点状态、说明与全部数量由服务端
// 一次算好(ADR-143 §三「只在服务端算一次」)；客户端只显示，不做加减推算。
// 物料行与委外任务详情物料表同字段，直接复用 [SubcontractDrawMaterial]。
import 'subcontract_draw.dart';

/// 委外任务的物料方式(服务端 materialMode)。
enum SubcontractItemMaterialMode {
  /// 按工序领直属物料发外。
  draw,

  /// 委外件还没有维护可发外的直属物料(缺 BOM)，不能提交财务(ADR-143 §二.3)。
  missingBom;

  static SubcontractItemMaterialMode fromWire(Object? value) =>
      value?.toString().trim().toUpperCase() == 'MISSING_BOM'
      ? missingBom
      : draw;
}

/// 时间线节点状态。服务端新增而本端不认识的值按「未开始」显示。
enum SubcontractProgressNodeState {
  done,
  active,
  pending,
  skipped;

  static SubcontractProgressNodeState fromWire(Object? value) =>
      switch (value?.toString().trim().toUpperCase()) {
        'DONE' => done,
        'ACTIVE' => active,
        'SKIPPED' => skipped,
        _ => pending,
      };
}

/// 时间线节点：key ∈ ORDER / FINANCE / DRAW / RETURN / QUALITY / STOCK_IN / CLOSE。
class SubcontractProgressNode {
  const SubcontractProgressNode({
    required this.key,
    required this.label,
    required this.state,
    this.detail,
  });

  final String key;
  final String label;
  final SubcontractProgressNodeState state;

  /// 面向人的说明，如「已领 40/100 件，待仓库发 10 件」。
  final String? detail;

  factory SubcontractProgressNode.fromJson(Map<String, dynamic> json) {
    final key = _string(json, 'key')?.toUpperCase() ?? '';
    return SubcontractProgressNode(
      key: key,
      label: _string(json, 'label') ?? _defaultNodeLabels[key] ?? '进度',
      state: SubcontractProgressNodeState.fromWire(json['state']),
      detail: _string(json, 'detail'),
    );
  }
}

const _defaultNodeLabels = <String, String>{
  'ORDER': '下单',
  'FINANCE': '财务审批',
  'DRAW': '领料发外',
  'RETURN': '加工回厂',
  'QUALITY': '品质检验',
  'STOCK_IN': '仓库确认入仓',
  'CLOSE': '结案核销',
};

/// 一个委外任务(订货明细)的进度。数量全部为订货单位；物料行用物料自己的单位。
class SubcontractItemProgress {
  const SubcontractItemProgress({
    required this.orderItemId,
    required this.lineNo,
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.orderQty,
    required this.materialMode,
    required this.drawOpen,
    required this.materialKindCount,
    required this.readyKindCount,
    required this.drawnQty,
    required this.pendingQty,
    required this.drawableQty,
    required this.shortQty,
    required this.returnableQty,
    required this.receivedQty,
    required this.qualifiedQty,
    required this.pendingInspectionQty,
    required this.stockedQty,
    required this.settledLossQty,
    required this.materials,
    required this.timeline,
  });

  final String orderItemId;
  final int? lineNo;
  final String goodsCode;
  final String goodsName;
  final String colorName;
  final String unitName;
  final double orderQty;
  final SubcontractItemMaterialMode materialMode;

  /// 还有未结束领料的物料行。
  final bool drawOpen;
  final int materialKindCount;

  /// 仓库可用已够、不再缺的物料种数。
  final int readyKindCount;

  /// 已领 / 待仓库发 / 可领 / 还缺(批准后四者之和 = 订货数量)。
  final double drawnQty;
  final double pendingQty;
  final double drawableQty;
  final double shortQty;

  /// 委外商处物料能做成的完整套数。
  final double returnableQty;
  final double receivedQty;
  final double qualifiedQty;
  final double pendingInspectionQty;
  final double stockedQty;
  final double settledLossQty;
  final List<SubcontractDrawMaterial> materials;
  final List<SubcontractProgressNode> timeline;

  bool get bomMissing => materialMode == SubcontractItemMaterialMode.missingBom;

  factory SubcontractItemProgress.fromJson(Map<String, dynamic> json) =>
      SubcontractItemProgress(
        orderItemId: _string(json, 'orderItemId') ?? '',
        lineNo: (json['lineNo'] as num?)?.toInt(),
        goodsCode: _string(json, 'goodsCode') ?? '',
        goodsName: _string(json, 'goodsName') ?? '',
        colorName: _string(json, 'colorName') ?? '',
        unitName: _string(json, 'unitName') ?? '',
        orderQty: _double(json, 'orderQty'),
        materialMode: SubcontractItemMaterialMode.fromWire(
          json['materialMode'],
        ),
        drawOpen: json['drawOpen'] == true,
        materialKindCount: (json['materialKindCount'] as num?)?.toInt() ?? 0,
        readyKindCount: (json['readyKindCount'] as num?)?.toInt() ?? 0,
        drawnQty: _double(json, 'drawnQty'),
        pendingQty: _double(json, 'pendingQty'),
        drawableQty: _double(json, 'drawableQty'),
        shortQty: _double(json, 'shortQty'),
        returnableQty: _double(json, 'returnableQty'),
        receivedQty: _double(json, 'receivedQty'),
        qualifiedQty: _double(json, 'qualifiedQty'),
        pendingInspectionQty: _double(json, 'pendingInspectionQty'),
        stockedQty: _double(json, 'stockedQty'),
        settledLossQty: _double(json, 'settledLossQty'),
        materials: _list(json['materials'], SubcontractDrawMaterial.fromJson),
        timeline: _list(json['timeline'], SubcontractProgressNode.fromJson),
      );
}

/// 链路单据进度(领料出仓单/回厂进仓单/退货单/损耗单共用)。
class SubcontractProgressDoc {
  const SubcontractProgressDoc({
    required this.id,
    required this.billNo,
    required this.status,
    required this.billDate,
    this.warehouseName,
    this.approverName,
    this.totalQty,
    this.totalLocal,
    this.iqcStatus,
    this.warehouseStockInStatus,
    this.iqcPassedBaseQty,
    this.warehouseStockedBaseQty,
    this.pendingStockInBaseQty,
    this.deductAmount,
    this.deductPosted,
  });

  final String id;
  final String? billNo;

  /// 0 草稿(领料出仓单 = 已提交领料、仓库未发出) / 1 已审 / -1 红冲。
  final int? status;
  final String? billDate;
  final String? warehouseName;
  final String? approverName;
  final double? totalQty;
  final double? totalLocal;

  /// IQC 聚合状态(仅进仓单)：PENDING / PARTIAL / RESOLVED / REVERSED。
  final String? iqcStatus;

  /// 仓库实际入库状态(仅进仓单)。只有服务端明确返回 STOCKED 才表示已进入库存；
  /// null/未知值按「待回传」显示，不能从 IQC RESOLVED 或当前库存反推。
  final String? warehouseStockInStatus;
  final double? iqcPassedBaseQty;
  final double? warehouseStockedBaseQty;
  final double? pendingStockInBaseQty;

  /// 损耗建议索赔金额(仅损耗单；不自动扣款或冲应付)。
  final double? deductAmount;

  /// 历史扣款标记；新流程不据此表达已冲应付。
  final bool? deductPosted;

  factory SubcontractProgressDoc.fromJson(Map<String, dynamic> json) =>
      SubcontractProgressDoc(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        status: (json['status'] as num?)?.toInt(),
        billDate: json['billDate'] as String?,
        warehouseName: json['warehouseName'] as String?,
        approverName: json['approverName'] as String?,
        totalQty: (json['totalQty'] as num?)?.toDouble(),
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        iqcStatus: json['iqcStatus'] as String?,
        warehouseStockInStatus: json['warehouseStockInStatus'] as String?,
        iqcPassedBaseQty: (json['iqcPassedBaseQty'] as num?)?.toDouble(),
        warehouseStockedBaseQty: (json['warehouseStockedBaseQty'] as num?)
            ?.toDouble(),
        pendingStockInBaseQty: (json['pendingStockInBaseQty'] as num?)
            ?.toDouble(),
        deductAmount: (json['deductAmount'] as num?)?.toDouble(),
        deductPosted: json['deductPosted'] as bool?,
      );
}

/// 委外商处物料台账行(V221 守恒口径，按物料聚合)。
class SubcontractSupplierLedgerLine {
  const SubcontractSupplierLedgerLine({
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.atSupplierQty,
    required this.consumedQty,
    required this.returnedQty,
    required this.wastedQty,
    required this.supplierEnding,
  });

  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double atSupplierQty;
  final double consumedQty;
  final double returnedQty;
  final double wastedQty;
  final double supplierEnding;

  factory SubcontractSupplierLedgerLine.fromJson(Map<String, dynamic> json) =>
      SubcontractSupplierLedgerLine(
        goodsCode: json['goodsCode'] as String?,
        goodsName: json['goodsName'] as String?,
        colorName: json['colorName'] as String?,
        unitName: json['unitName'] as String?,
        atSupplierQty: (json['atSupplierQty'] as num?)?.toDouble() ?? 0,
        consumedQty: (json['consumedQty'] as num?)?.toDouble() ?? 0,
        returnedQty: (json['returnedQty'] as num?)?.toDouble() ?? 0,
        wastedQty: (json['wastedQty'] as num?)?.toDouble() ?? 0,
        supplierEnding: (json['supplierEnding'] as num?)?.toDouble() ?? 0,
      );
}

class SubcontractOrderProgress {
  const SubcontractOrderProgress({
    required this.orderId,
    required this.billNo,
    required this.status,
    required this.financeCaseStatus,
    required this.financeDecidedAt,
    required this.planStatus,
    required this.planCloseReason,
    required this.items,
    required this.issues,
    required this.receipts,
    required this.returns,
    required this.wastes,
    required this.supplierLedger,
    required this.apPostedTotal,
    required this.wasteDeductTotal,
    this.priceMasked = false,
  });

  final String orderId;
  final String? billNo;
  final int? status;
  final String? financeCaseStatus; // PENDING / APPROVED / REJECTED
  final String? financeDecidedAt;

  /// 领料计划状态：OPEN / CLOSED / CANCELED；未批准时为 null。
  final String? planStatus;
  final String? planCloseReason;

  /// 每条订货明细一个委外任务。
  final List<SubcontractItemProgress> items;
  final List<SubcontractProgressDoc> issues;
  final List<SubcontractProgressDoc> receipts;
  final List<SubcontractProgressDoc> returns;
  final List<SubcontractProgressDoc> wastes;
  final List<SubcontractSupplierLedgerLine> supplierLedger;
  final double apPostedTotal;

  /// 后端历史字段名；前端按「建议索赔合计(不计入应付)」展示。
  final double wasteDeductTotal;

  /// 服务端判定当前账号不能看委外商业金额时为 true(金额字段已置空)。
  final bool priceMasked;

  factory SubcontractOrderProgress.fromJson(Map<String, dynamic> json) =>
      SubcontractOrderProgress(
        orderId: json['orderId'] as String,
        billNo: json['billNo'] as String?,
        status: (json['status'] as num?)?.toInt(),
        financeCaseStatus: json['financeCaseStatus'] as String?,
        financeDecidedAt: json['financeDecidedAt'] as String?,
        planStatus: json['planStatus'] as String?,
        planCloseReason: json['planCloseReason'] as String?,
        items: _list(json['items'], SubcontractItemProgress.fromJson),
        issues: _list(json['issues'], SubcontractProgressDoc.fromJson),
        receipts: _list(json['receipts'], SubcontractProgressDoc.fromJson),
        returns: _list(json['returns'], SubcontractProgressDoc.fromJson),
        wastes: _list(json['wastes'], SubcontractProgressDoc.fromJson),
        supplierLedger: _list(
          json['supplierLedger'],
          SubcontractSupplierLedgerLine.fromJson,
        ),
        apPostedTotal: (json['apPostedTotal'] as num?)?.toDouble() ?? 0,
        wasteDeductTotal: (json['wasteDeductTotal'] as num?)?.toDouble() ?? 0,
        priceMasked: json['priceMasked'] == true,
      );
}

String? _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

double _double(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? 0;
  return 0;
}

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) fromJson) => [
  for (final row in (raw as List? ?? const []))
    if (row is Map) fromJson(row.cast<String, dynamic>()),
];
