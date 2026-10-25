import '../../../shared/models/procurement_order_closure.dart';
import '../../../shared/documents/imported_document_policy.dart';
import '../../../shared/models/procurement_quantity.dart';
import '../../../shared/models/procurement_source_terms.dart';
import '../../../shared/business_columns/business_column.dart';
import '../../../shared/widgets/warehouse_selection.dart';
// 采购单据模型（4 单据统一超集，对应后端 *ListItem/*Detail/*ItemDto）。
//
// 4 单据差异由 doc_type 决定可选字段是否非空（申请无供应商/币种；收货有 sender/receiver；
// 退货明细有 receiptItemId+orderItemId；等）。一个超集模型 ×4 配置，避免 4 套重复。
// UUID=String；金额/数量=(json as num?)；日期=ISO 字符串直存（后端 LocalDate）。

import '../../../shared/models/procurement_finance_approval.dart';
import '../../../shared/models/historical_receipt_facts.dart';

/// 采购单据类型。pathSegment 对齐后端 /api/purchase/{requests|orders|receipts|returns}。
enum PurchaseDocType {
  request('requests'),
  order('orders'),
  receipt('receipts'),
  returnDoc('returns');

  const PurchaseDocType(this.pathSegment);
  final String pathSegment;

  /// 表头仓库的选仓用途(ADR-146)：退货可以从不良品仓退供应商，其余都只落良品仓。
  WarehouseUse get warehouseUse =>
      this == returnDoc ? WarehouseUse.disposalOut : WarehouseUse.goodIn;

  static PurchaseDocType? tryByPath(String seg) {
    for (final type in PurchaseDocType.values) {
      if (type.pathSegment == seg) return type;
    }
    return null;
  }

  static PurchaseDocType byPath(String seg) =>
      tryByPath(seg) ?? (throw ArgumentError.value(seg, 'seg', '未知采购单据路由段'));
}

/// 单据状态：0草稿 / 1已审 / -1红冲 / 2已取消（2026-09-05 起草稿单可取消，
/// 保留轨迹；在审单取消时审批 case 同步置 CANCELED）。
const int kPurchaseStatusDraft = 0;
const int kPurchaseStatusApproved = 1;
const int kPurchaseStatusReversed = -1;
const int kPurchaseStatusCanceled = 2;

String purchaseStatusLabel(int? code) {
  switch (code) {
    case kPurchaseStatusDraft:
      return '草稿';
    case kPurchaseStatusApproved:
      return '已审';
    case kPurchaseStatusReversed:
      return '已反审';
    case kPurchaseStatusCanceled:
      return '已取消';
    default:
      return '—';
  }
}

/// 订货单展示状态文案（列表状态列与详情「状态」徽章共用口径）：财务通过前
/// 单据 status 保持 0，在审/退回期间以 financeApproval 投影为准——
/// PENDING=等待财务审核 / REJECTED=财务退回 / APPROVED=财务已通过 /
/// DRAFT=待提交财务；红冲/已取消终态与无投影/未知态回落单据状态文案。
String purchaseOrderDisplayLabel(
  int? status,
  ProcurementFinanceApproval? financeApproval,
) {
  if (status == kPurchaseStatusReversed || status == kPurchaseStatusCanceled) {
    return purchaseStatusLabel(status);
  }
  if (status == kPurchaseStatusApproved) {
    if (financeApproval?.isPending == true) return '改量待财务复核';
    if (financeApproval?.isRejected == true) return '改量财务退回';
  }
  return switch (financeApproval?.status) {
    'PENDING' => '等待财务审核',
    'REJECTED' => '财务退回',
    'APPROVED' => '财务已通过',
    'DRAFT' => '待提交财务',
    _ => purchaseStatusLabel(status),
  };
}

/// ADR-144 允许超收量 T(q, p) = ROUND(q × p / 100, 4)（订货单位，四舍五入；
/// 比例为空或不大于 0 时为 0）。与服务端 fn_purchase_over_receipt_tolerance 同式，
/// 前端只用于默认值与展示，收货是否放行以服务端为准。
double purchaseOverReceiptTolerance(double qty, double? pct) {
  if (pct == null || pct <= 0 || qty <= 0) return 0;
  return (qty * pct / 100 * 10000).round() / 10000;
}

/// 百分比显示：整数不带小数点，其余最多两位并去掉尾零（5.0 → 5，2.50 → 2.5）。
String purchasePercentText(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value
          .toStringAsFixed(2)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');

double? _decimalOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

class PurchaseDocListItem {
  const PurchaseDocListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.warehouseId,
    this.totalLocal,
    this.totalLocalText,
    this.priceMasked = false,
    this.status,
    this.closed = false,
    this.legacyId,
    bool legacyImported = false,
    this.financeApproval,
  }) : legacyImported = legacyImported || legacyId != null;

  final String id;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final double? totalLocal;
  final String? totalLocalText;

  /// 价格已对当前用户脱敏（金额族为 null；渲染 ***，V302 收货单价格脱敏）。
  final bool priceMasked;
  final int? status;
  final bool closed;
  final int? legacyId;
  final bool legacyImported;
  final ProcurementFinanceApproval? financeApproval;

  factory PurchaseDocListItem.fromJson(Map<String, dynamic> json) =>
      PurchaseDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        totalLocalText:
            json['priceMasked'] == true || json['totalLocal'] == null
            ? null
            : receiptRecordedDecimal(json, 'totalLocal'),
        priceMasked: (json['priceMasked'] as bool?) ?? false,
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        legacyImported: importedBusinessDocument(json),
        financeApproval: json['financeApproval'] is Map
            ? ProcurementFinanceApproval.fromJson(
                (json['financeApproval'] as Map).cast<String, dynamic>(),
              )
            : null,
      );
}

class PurchaseDocItem {
  const PurchaseDocItem({
    this.extraColumns = const [],
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.unitRateText,
    this.unitRateExactText,
    this.qty,
    this.qtyText,
    this.rowVersion,
    this.price,
    this.priceText,
    this.totalAmountInputText,
    this.amountOriginal,
    this.amountOriginalText,
    this.amountLocal,
    this.amountLocalText,
    this.orderedQty,
    this.orderedQtyText,
    this.pendingQty,
    this.pendingQtyText,
    this.remainingQty,
    this.remainingQtyText,
    this.receivedQty,
    this.receivedQtyText,
    this.returnedQty,
    this.returnedQtyText,
    this.giftQty,
    this.returnableGiftQtyText,
    this.remainingGiftQtyText,
    this.giftStockedQtyText,
    this.giftReturnedQtyText,
    this.giftReceivedQtyText,
    this.giftOrderedQtyText,
    this.physicalQtyText,
    this.pendingGiftQtyText,
    this.physicalOrderedQtyText,
    this.physicalPendingQtyText,
    this.physicalRemainingQtyText,
    this.quantitySemantics,
    this.giftQtyText,
    this.replacementIntent,
    this.giftReplacementIntent,
    this.requestItemId,
    this.orderItemId,
    this.orderId,
    this.orderBillNo,
    this.receiptItemId,
    this.deliverDate,
    this.weight,
    this.sourceDocNo,
    this.productionPlanNo,
    this.salesOrderNo,
    this.remark,
    this.allowedOverReceiptPct,
    this.sourceRequests = const [],
  });

  final List<BusinessColumn> extraColumns;
  final String? id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final String? unitRateText;
  final String? unitRateExactText;
  final double? qty;
  final String? qtyText;

  /// Persistent request-line CAS version. Missing/invalid versions stay unknown;
  /// they must never become an invented zero when editing an older DTO.
  final int? rowVersion;
  final double? price;
  final String? priceText;

  /// Recorded base total before additional columns; unit price may be a reference.
  final String? totalAmountInputText;
  final double? amountOriginal;
  final String? amountOriginalText;
  final double? amountLocal;
  final String? amountLocalText;
  final double? orderedQty;
  final String? orderedQtyText;
  final double? pendingQty;
  final String? pendingQtyText;
  final double? remainingQty;
  final String? remainingQtyText;
  final double? receivedQty;
  final String? receivedQtyText;
  final double? returnedQty;
  final String? returnedQtyText;
  final double? giftQty;
  final String? returnableGiftQtyText;
  final String? remainingGiftQtyText;
  final String? giftStockedQtyText;
  final String? giftReturnedQtyText;
  final String? giftReceivedQtyText;
  final String? giftOrderedQtyText;
  final String? physicalQtyText;
  final String? pendingGiftQtyText;
  final String? physicalOrderedQtyText;
  final String? physicalPendingQtyText;
  final String? physicalRemainingQtyText;
  final String? quantitySemantics;
  final String? giftQtyText;
  final String? replacementIntent;
  final String? giftReplacementIntent;
  final String? requestItemId;
  final String? orderItemId;

  /// 来源订货单 id（收货/进仓明细级，点击跳订货详情用）；无订货关联为 null。
  final String? orderId;

  /// 来源订货单编号（收货/进仓明细级展示：编号而非 id）；无订货关联为 null。
  final String? orderBillNo;
  final String? receiptItemId;
  final String? deliverDate;
  final double? weight;
  final String? sourceDocNo;
  final String? productionPlanNo;
  final String? salesOrderNo;
  final String? remark;

  /// 订货明细允许超收%（ADR-144，0..100；空 = 不允许超收，按 0%）。
  /// 冻结在明细上，财务批准后不能再改；不受价格遮蔽。
  final double? allowedOverReceiptPct;

  /// 允许超收量 T = ROUND(数量 × 允许超收% / 100, 4)（订货单位）。
  double get allowedOverReceiptQty =>
      purchaseOverReceiptTolerance(qty ?? 0, allowedOverReceiptPct);

  /// 全部来源申请（V463 同货品合并行多来源）：明细 id + 申请单 id + 单号，
  /// 稳定顺序与 sources.line_no 一致；单来源行一条、手工/历史行为空。
  final List<PurchaseSourceRequestRef> sourceRequests;

  bool get hasExtraGift =>
      quantitySemantics == procurementChargedPlusGiftQuantity;
  String? get recordedPhysicalQtyText =>
      physicalQtyText ??
      procurementPhysicalQuantityText(
        quantitySemantics: quantitySemantics ?? procurementLegacyQuantity,
        chargedQty: qtyText ?? qty?.toString(),
        giftQty: giftQtyText ?? giftQty?.toString() ?? '0',
      );

  factory PurchaseDocItem.fromJson(
    Map<String, dynamic> json,
  ) => PurchaseDocItem(
    extraColumns: BusinessColumn.read(json['extraColumns']),
    id: json['id'] as String?,
    lineNo: (json['lineNo'] as num?)?.toInt(),
    goodsId: json['goodsId'] as String?,
    colorId: json['colorId'] as String?,
    unitId: json['unitId'] as String?,
    unitRate: (json['unitRate'] as num?)?.toDouble(),
    unitRateText: receiptRecordedDecimal(json, 'unitRate'),
    unitRateExactText: json.containsKey('unitRateExact')
        ? json['unitRateExact']?.toString() ?? ''
        : null,
    qty: (json['qty'] as num?)?.toDouble(),
    qtyText: receiptRecordedDecimal(json, 'qty'),
    rowVersion: json['rowVersion'] is int && (json['rowVersion'] as int) >= 0
        ? json['rowVersion'] as int
        : null,
    price: (json['price'] as num?)?.toDouble(),
    priceText: receiptRecordedDecimal(json, 'price'),
    totalAmountInputText: receiptRecordedDecimal(json, 'totalAmountInput'),
    amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
    amountOriginalText: receiptRecordedDecimal(json, 'amountOriginal'),
    amountLocal: (json['amountLocal'] as num?)?.toDouble(),
    amountLocalText: receiptRecordedDecimal(json, 'amountLocal'),
    orderedQty: (json['orderedQty'] as num?)?.toDouble(),
    orderedQtyText: receiptRecordedDecimal(json, 'orderedQty'),
    pendingQty: (json['pendingQty'] as num?)?.toDouble(),
    pendingQtyText: receiptRecordedDecimal(json, 'pendingQty'),
    remainingQty: (json['remainingQty'] as num?)?.toDouble(),
    remainingQtyText: receiptRecordedDecimal(json, 'remainingQty'),
    receivedQty: (json['receivedQty'] as num?)?.toDouble(),
    receivedQtyText: receiptRecordedDecimal(json, 'receivedQty'),
    returnedQty: (json['returnedQty'] as num?)?.toDouble(),
    returnedQtyText: receiptRecordedDecimal(json, 'returnedQty'),
    giftQty: (json['giftQty'] as num?)?.toDouble(),
    quantitySemantics: json['quantitySemantics'] as String?,
    returnableGiftQtyText: receiptRecordedDecimal(json, 'returnableGiftQty'),
    remainingGiftQtyText: receiptRecordedDecimal(json, 'remainingGiftQty'),
    giftStockedQtyText: receiptRecordedDecimal(json, 'giftStockedQty'),
    giftReturnedQtyText: receiptRecordedDecimal(json, 'giftReturnedQty'),
    giftReceivedQtyText: receiptRecordedDecimal(json, 'giftReceivedQty'),
    giftOrderedQtyText: receiptRecordedDecimal(json, 'giftOrderedQty'),
    physicalQtyText: receiptRecordedDecimal(json, 'physicalQty'),
    pendingGiftQtyText: receiptRecordedDecimal(json, 'pendingGiftQty'),
    physicalOrderedQtyText: receiptRecordedDecimal(json, 'physicalOrderedQty'),
    physicalPendingQtyText: receiptRecordedDecimal(json, 'physicalPendingQty'),
    physicalRemainingQtyText: receiptRecordedDecimal(
      json,
      'physicalRemainingQty',
    ),
    giftQtyText: receiptRecordedDecimal(json, 'giftQty'),
    replacementIntent: json['replacementIntent'] as String?,
    giftReplacementIntent: json['giftReplacementIntent'] as String?,
    requestItemId: json['requestItemId'] as String?,
    orderItemId: json['orderItemId'] as String?,
    orderId: json['orderId'] as String?,
    orderBillNo: json['orderBillNo'] as String?,
    receiptItemId: json['receiptItemId'] as String?,
    deliverDate: json['deliverDate'] as String?,
    weight: (json['weight'] as num?)?.toDouble(),
    sourceDocNo: json['sourceDocNo'] as String?,
    productionPlanNo: json['productionPlanNo'] as String?,
    salesOrderNo: json['salesOrderNo'] as String?,
    remark: json['remark'] as String?,
    allowedOverReceiptPct: _decimalOrNull(json['allowedOverReceiptPct']),
    sourceRequests: [
      for (final entry
          in (json['sourceRequests'] as List<dynamic>? ?? const <dynamic>[]))
        PurchaseSourceRequestRef.fromJson(entry as Map<String, dynamic>),
    ],
  );
}

/// 订货行的来源采购申请引用（V463 合并行多来源）。
class PurchaseSourceRequestRef {
  const PurchaseSourceRequestRef({
    required this.requestItemId,
    this.requestId,
    this.billNo,
  });

  final String requestItemId;
  final String? requestId;
  final String? billNo;

  factory PurchaseSourceRequestRef.fromJson(Map<String, dynamic> json) =>
      PurchaseSourceRequestRef(
        requestItemId: json['requestItemId'] as String,
        requestId: json['requestId'] as String?,
        billNo: json['billNo'] as String?,
      );
}

class PurchaseDocDetail {
  const PurchaseDocDetail({
    required this.id,
    this.legacyId,
    bool legacyImported = false,
    this.billNo,
    this.billDate,
    this.supplierId,
    this.warehouseId,
    this.departmentId,
    this.currencyId,
    this.exchangeRate,
    this.exchangeRateText,
    this.effectiveFinanceExchangeRate,
    this.taxRateText,
    this.taxRate,
    this.applicantId,
    this.applicantName,
    this.purchaserId,
    this.purchaserName,
    this.settlementMethodId,
    this.settlementStyleLegacy,
    this.senderId,
    this.senderName,
    this.receiverId,
    this.receiverName,
    this.makerId,
    this.approverId,
    this.makerName,
    this.createdAt,
    this.needDate,
    this.deliverDate,
    this.remark,
    this.totalOriginal,
    this.totalOriginalText,
    this.totalLocal,
    this.totalLocalText,
    this.priceMasked = false,
    this.status,
    this.closed = false,
    this.sourceDocNo,
    this.items = const [],
    this.productionLinked = false,
    this.canEdit = false,
    this.canDelete = false,
    this.canReverse = false,
    this.restrictionReason,
    this.financeApproval,
    this.closureRequest,
    this.priceAssessment,
    this.sourceRequestId,
    this.sourceRequestNo,
    this.sourceOrderId,
    this.sourceOrderNo,
  }) : legacyImported = legacyImported || legacyId != null;

  final String id;
  final int? legacyId;
  final bool legacyImported;
  final String? billNo;
  final String? billDate;
  final String? supplierId;
  final String? warehouseId;
  final String? departmentId;
  final String? currencyId;
  final double? exchangeRate;
  final String? exchangeRateText;
  final String? effectiveFinanceExchangeRate;
  final String? taxRateText;
  final double? taxRate;
  final String? applicantId;
  final String? applicantName;
  final String? purchaserId;

  /// 采购员「姓名(工号)」（服务端按 purchaserId 解析；旧后端未下发时退回本地字典）
  final String? purchaserName;

  final String? settlementMethodId;
  final int? settlementStyleLegacy;
  final String? senderId;

  /// 交货人「姓名(工号)」（服务端按 senderId 解析；旧后端未下发时退回本地字典）
  final String? senderName;

  final String? receiverId;

  /// 收货人「姓名(工号)」（服务端按 receiverId 解析；旧后端未下发时退回本地字典）
  final String? receiverName;

  final String? makerId;
  final String? approverId;

  /// 制单员「姓名(工号)」（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final String? needDate;
  final String? deliverDate;
  final String? remark;
  final double? totalOriginal;
  final String? totalOriginalText;
  final double? totalLocal;
  final String? totalLocalText;

  /// 价格已对当前用户脱敏（金额族/明细价格族为 null；渲染 ***，V302 收货单价格脱敏）。
  final bool priceMasked;
  final int? status;
  final bool closed;
  final String? sourceDocNo;
  final List<PurchaseDocItem> items;
  final bool productionLinked;
  final bool canEdit;
  final bool canDelete;
  final bool canReverse;
  final String? restrictionReason;
  final ProcurementFinanceApproval? financeApproval;
  final ProcurementOrderClosureRequest? closureRequest;
  final Map<String, dynamic>? priceAssessment;

  /// 来源采购申请（订货单全部明细同源时给出，供跳转；跨申请分解为 null）
  final String? sourceRequestId;
  final String? sourceRequestNo;

  /// 来源采购订货单（收货单全部明细同源时给出，供跳转；跨订单为 null）
  final String? sourceOrderId;
  final String? sourceOrderNo;

  factory PurchaseDocDetail.fromJson(Map<String, dynamic> json) =>
      PurchaseDocDetail(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        legacyImported: importedBusinessDocument(json),
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        supplierId: json['supplierId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        departmentId: json['departmentId'] as String?,
        currencyId: json['currencyId'] as String?,
        exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
        exchangeRateText: receiptRecordedDecimal(json, 'exchangeRate'),
        effectiveFinanceExchangeRate: receiptRecordedDecimal(
          json,
          'effectiveFinanceExchangeRate',
        ),
        taxRateText: receiptRecordedDecimal(json, 'taxRate'),
        taxRate: (json['taxRate'] as num?)?.toDouble(),
        applicantId: json['applicantId'] as String?,
        applicantName: json['applicantName'] as String?,
        purchaserId: json['purchaserId'] as String?,
        purchaserName: json['purchaserName'] as String?,
        settlementMethodId: json['settlementMethodId'] as String?,
        settlementStyleLegacy: (json['settlementStyleLegacy'] as num?)?.toInt(),
        senderId: json['senderId'] as String?,
        senderName: json['senderName'] as String?,
        receiverId: json['receiverId'] as String?,
        receiverName: json['receiverName'] as String?,
        makerId: json['makerId'] as String?,
        makerName: json['makerName'] as String?,
        createdAt: json['createdAt'] as String?,
        approverId: json['approverId'] as String?,
        needDate: json['needDate'] as String?,
        deliverDate: json['deliverDate'] as String?,
        remark: json['remark'] as String?,
        totalOriginal: (json['totalOriginal'] as num?)?.toDouble(),
        totalOriginalText: receiptRecordedDecimal(json, 'totalOriginal'),
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        totalLocalText: receiptRecordedDecimal(json, 'totalLocal'),
        priceMasked: (json['priceMasked'] as bool?) ?? false,
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        sourceDocNo: json['sourceDocNo'] as String?,
        productionLinked: (json['productionLinked'] as bool?) ?? false,
        canEdit: (json['canEdit'] as bool?) ?? false,
        canDelete: (json['canDelete'] as bool?) ?? false,
        canReverse: (json['canReverse'] as bool?) ?? false,
        restrictionReason: json['restrictionReason'] as String?,
        sourceRequestId: json['sourceRequestId'] as String?,
        sourceRequestNo: json['sourceRequestNo'] as String?,
        sourceOrderId: json['sourceOrderId'] as String?,
        sourceOrderNo: json['sourceOrderNo'] as String?,
        priceAssessment: json['priceAssessment'] is Map<String, dynamic>
            ? json['priceAssessment'] as Map<String, dynamic>
            : null,
        closureRequest: json['closureRequest'] is Map
            ? ProcurementOrderClosureRequest.fromJson(
                (json['closureRequest'] as Map).cast<String, dynamic>(),
              )
            : null,
        financeApproval: json['financeApproval'] is Map
            ? ProcurementFinanceApproval.fromJson(
                (json['financeApproval'] as Map).cast<String, dynamic>(),
              )
            : null,
        items:
            (json['items'] as List?)
                ?.map(
                  (e) => PurchaseDocItem.fromJson(e as Map<String, dynamic>),
                )
                .toList() ??
            const [],
      );

  ProcurementSourceTerms sourceCommercialTerms({required bool orderSource}) =>
      ProcurementSourceTerms(
        currencyId: currencyId,
        exchangeRate: priceMasked
            ? null
            : orderSource
            ? effectiveFinanceExchangeRate ??
                  exchangeRateText ??
                  exchangeRate?.toString()
            : exchangeRateText ?? exchangeRate?.toString(),
        taxRate: taxRateText ?? taxRate?.toString(),
        settlementMethodId: settlementMethodId,
      );
}

class ProcurementDecompositionLine {
  const ProcurementDecompositionLine({
    required this.sourceDocumentId,
    required this.sourceDocumentNo,
    required this.sourceItemId,
    required this.goodsId,
    required this.requestedQty,
    required this.orderedQty,
    required this.pendingQty,
    required this.remainingQty,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.needDate,
    this.warehouseId,
    this.sourcePlanNo,
    this.requestedQtyText,
    this.orderedQtyText,
    this.pendingQtyText,
    this.remainingQtyText,
    this.unitRateText,
    this.unitRateExactText,
    this.quantitySemantics = procurementLegacyQuantity,
    this.giftQty = 0,
    this.giftOrderedQty = 0,
    this.pendingGiftQty = 0,
    this.remainingGiftQty = 0,
    this.physicalRemainingQty,
    this.giftQtyText,
    this.giftOrderedQtyText,
    this.pendingGiftQtyText,
    this.remainingGiftQtyText,
    this.physicalQtyText,
    this.physicalOrderedQtyText,
    this.physicalPendingQtyText,
    this.physicalRemainingQtyText,
  });

  final String sourceDocumentId;
  final String sourceDocumentNo;
  final String sourceItemId;
  final String goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double requestedQty;
  final double orderedQty;
  final double pendingQty;
  final double remainingQty;
  final String? needDate;
  final String? warehouseId;
  final String? sourcePlanNo;
  final String? requestedQtyText;
  final String? orderedQtyText;
  final String? pendingQtyText;
  final String? remainingQtyText;
  final String? unitRateText;
  final String? unitRateExactText;
  final String? quantitySemantics;
  final double giftQty;
  final double giftOrderedQty;
  final double pendingGiftQty;
  final double remainingGiftQty;
  final double? physicalRemainingQty;
  final String? giftQtyText;
  final String? giftOrderedQtyText;
  final String? pendingGiftQtyText;
  final String? remainingGiftQtyText;
  final String? physicalQtyText;
  final String? physicalOrderedQtyText;
  final String? physicalPendingQtyText;
  final String? physicalRemainingQtyText;

  String get chargedRemainingQtyText =>
      remainingQtyText ?? remainingQty.toString();

  String? get defaultGiftQtyText =>
      quantitySemantics == procurementChargedPlusGiftQuantity
      ? remainingGiftQtyText
      : quantitySemantics == null ||
            quantitySemantics == procurementLegacyQuantity
      ? '0'
      : null;

  String? get availablePhysicalQtyText =>
      physicalRemainingQtyText ??
      physicalRemainingQty?.toString() ??
      (quantitySemantics == null ||
              quantitySemantics == procurementLegacyQuantity
          ? remainingQtyText ?? remainingQty.toString()
          : null);

  factory ProcurementDecompositionLine.fromJson(Map<String, dynamic> json) {
    double number(String key) {
      return double.tryParse(receiptRecordedDecimal(json, key) ?? '') ?? 0;
    }

    return ProcurementDecompositionLine(
      sourceDocumentId: json['sourceDocumentId'] as String,
      sourceDocumentNo: json['sourceDocumentNo'] as String? ?? '',
      sourceItemId: json['sourceItemId'] as String,
      goodsId: json['goodsId'] as String,
      colorId: json['colorId'] as String?,
      unitId: json['unitId'] as String?,
      unitRate: receiptRecordedDecimal(json, 'unitRate') == null
          ? null
          : number('unitRate'),
      requestedQty: number('requestedQty'),
      orderedQty: number('orderedQty'),
      pendingQty: number('pendingQty'),
      remainingQty: number('remainingQty'),
      needDate: json['needDate'] as String?,
      warehouseId: json['warehouseId'] as String?,
      sourcePlanNo: json['sourcePlanNo'] as String?,
      requestedQtyText: receiptRecordedDecimal(json, 'requestedQty'),
      orderedQtyText: receiptRecordedDecimal(json, 'orderedQty'),
      pendingQtyText: receiptRecordedDecimal(json, 'pendingQty'),
      remainingQtyText: receiptRecordedDecimal(json, 'remainingQty'),
      unitRateText: receiptRecordedDecimal(json, 'unitRate'),
      unitRateExactText: json.containsKey('unitRateExact')
          ? json['unitRateExact']?.toString() ?? ''
          : null,
      quantitySemantics: json['quantitySemantics'] as String?,
      giftQty: number('giftQty'),
      giftOrderedQty: number('giftOrderedQty'),
      pendingGiftQty: number('pendingGiftQty'),
      remainingGiftQty: number('remainingGiftQty'),
      physicalRemainingQty:
          receiptRecordedDecimal(json, 'physicalRemainingQty') == null
          ? null
          : number('physicalRemainingQty'),
      giftQtyText: receiptRecordedDecimal(json, 'giftQty'),
      giftOrderedQtyText: receiptRecordedDecimal(json, 'giftOrderedQty'),
      pendingGiftQtyText: receiptRecordedDecimal(json, 'pendingGiftQty'),
      remainingGiftQtyText: receiptRecordedDecimal(json, 'remainingGiftQty'),
      physicalQtyText: receiptRecordedDecimal(json, 'physicalQty'),
      physicalOrderedQtyText: receiptRecordedDecimal(
        json,
        'physicalOrderedQty',
      ),
      physicalPendingQtyText: receiptRecordedDecimal(
        json,
        'physicalPendingQty',
      ),
      physicalRemainingQtyText: receiptRecordedDecimal(
        json,
        'physicalRemainingQty',
      ),
    );
  }
}
