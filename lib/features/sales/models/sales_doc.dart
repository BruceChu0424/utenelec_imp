// 销售单据模型（5 单据统一超集，对应后端 *ListItem/*Detail/*ItemDto）。
//
// 5 单据差异由 doc_type 决定可选字段是否非空（报价无仓库/币种；退货明细有 outItemId+
// orderItemId；出货明细有 orderItemId；等）。一个超集模型 ×5 配置，避免 5 套重复。
// UUID=String；金额/数量=(json as num?)；日期=ISO 字符串直存（后端 LocalDate）。
//
// 对应后端 DTO（server .../features/sales/{quote|order|shipment|other_shipment|ret}/dto）：
//  - ListItem：id/billNo/billDate/clientId/totalLocal/status/closed/legacyId 共有，
//    currencyId(除报价)、warehouseId(出/退)、outType(其它出货)、stopped(订货)、arPosted(出/退) 差异。
//  - Detail：超集含全字段（makerId/approverId/sourceDocNo 全有；sellerId 除报价；
//    senderId 出货/其它出货；contractInfo 订货；shipInfo 出货类；validUntil 报价；deliverDate 订货）。
//  - ItemDto：超集含全字段（orderItemId 出货/退货；outItemId 退货专属；shipped/returned 订货回写；
//    costAmount 出/退；parcel/carton 出货类；solution/responsible 退货专属）。
import 'package:flutter/material.dart';

/// 销售单据类型。pathSegment 对齐后端 /api/sales/{quotes|orders|shipments|other-shipments|returns}。
enum SalesDocType {
  quote('quotes'),
  order('orders'),
  shipment('shipments'),
  otherShipment('other-shipments'),
  returnDoc('returns');

  const SalesDocType(this.pathSegment);
  final String pathSegment;

  static SalesDocType byPath(String seg) => SalesDocType.values.firstWhere(
    (e) => e.pathSegment == seg,
    orElse: () => SalesDocType.quote,
  );
}

/// 报表 docType 参数（对应 GET /api/sales/reports/{docType}/detail 的 path 取值）。
String salesReportDocTypeCode(SalesDocType t) {
  switch (t) {
    case SalesDocType.quote:
      return 'QUOTE';
    case SalesDocType.order:
      return 'ORDER';
    case SalesDocType.shipment:
      return 'SHIPMENT';
    case SalesDocType.otherShipment:
      return 'OTHER_SHIPMENT';
    case SalesDocType.returnDoc:
      return 'RETURN';
  }
}

/// 单据状态：0草稿 / 1已审 / -1红冲（与采购一致）。
const int kSalesStatusDraft = 0;
const int kSalesStatusApproved = 1;
const int kSalesStatusReversed = -1;

String salesStatusLabel(int? code) {
  switch (code) {
    case kSalesStatusDraft:
      return '草稿';
    case kSalesStatusApproved:
      return '已审';
    case kSalesStatusReversed:
      return '红冲';
    default:
      return '—';
  }
}

/// 状态对应的主题色（徽章用）。
Color salesStatusColor(int? code, ThemeData theme) {
  switch (code) {
    case kSalesStatusDraft:
      return theme.colorScheme.onSurfaceVariant;
    case kSalesStatusApproved:
      return Colors.green;
    case kSalesStatusReversed:
      return theme.colorScheme.error;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

/// 订单行优先级标签（V178 priority）：1急单/2普通/3现货。仅稀缺让单决策用。
String priorityLabel(int? p) {
  switch (p) {
    case 1:
      return '急单';
    case 2:
      return '普通';
    case 3:
      return '现货';
    default:
      return '现货';
  }
}

/// 订单行链路状态（V90 chain_status）标签。
String chainStatusLabel(int? code) {
  switch (code) {
    case 1:
      return '部分预留';
    case 2:
      return '待排产';
    case 3:
      return '待物料';
    case 4:
      return '已排产';
    case 5:
      return '生产中';
    case 6:
      return '部分完工';
    case 7:
      return '可发货';
    case 8:
      return '部分发货';
    case 9:
      return '已发货';
    case -1:
      return '已取消';
    default:
      return '—';
  }
}

/// 链路状态色（绿=可发货/完成，橙=进行中，红=缺料，灰=未上链）。
Color chainStatusColor(int? code, ThemeData theme) {
  switch (code) {
    case 7:
    case 9:
      return Colors.green;
    case 3:
      return theme.colorScheme.error;
    case 1:
    case 2:
    case 4:
    case 5:
    case 6:
    case 8:
      return Colors.orange;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

/// 订货工作台统计卡（GET /api/sales/orders/stats）。
class SalesOrderStats {
  const SalesOrderStats({
    this.pendingProduction = 0,
    this.inProduction = 0,
    this.shippable = 0,
    this.monthDone = 0,
  });
  final int pendingProduction;
  final int inProduction;
  final int shippable;
  final int monthDone;

  factory SalesOrderStats.fromJson(Map<String, dynamic> json) =>
      SalesOrderStats(
        pendingProduction: (json['pendingProduction'] as num?)?.toInt() ?? 0,
        inProduction: (json['inProduction'] as num?)?.toInt() ?? 0,
        shippable: (json['shippable'] as num?)?.toInt() ?? 0,
        monthDone: (json['monthDone'] as num?)?.toInt() ?? 0,
      );
}

/// 批量发货可发行（GET /api/sales/orders/shippable-lines；SOP §一9）。
/// 已审未结案订单中 reservedQty>0 的明细行，归属隔离与订单列表同口径。
class ShippableLine {
  const ShippableLine({
    required this.orderItemId,
    required this.orderId,
    this.billNo,
    this.clientId,
    this.deliverDate,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.qty,
    this.shippedQty,
    this.reservedQty,
    this.price,
    this.writable = false,
  });

  final String orderItemId;
  final String orderId;
  final String? billNo;
  final String? clientId;
  final String? deliverDate;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double? qty;
  final double? shippedQty;
  final double? reservedQty;
  final double? price;
  final bool writable;

  factory ShippableLine.fromJson(Map<String, dynamic> json) => ShippableLine(
    orderItemId: json['orderItemId'] as String,
    orderId: json['orderId'] as String,
    billNo: json['billNo'] as String?,
    clientId: json['clientId'] as String?,
    deliverDate: json['deliverDate'] as String?,
    goodsId: json['goodsId'] as String?,
    colorId: json['colorId'] as String?,
    unitId: json['unitId'] as String?,
    unitRate: (json['unitRate'] as num?)?.toDouble(),
    qty: (json['qty'] as num?)?.toDouble(),
    shippedQty: (json['shippedQty'] as num?)?.toDouble(),
    reservedQty: (json['reservedQty'] as num?)?.toDouble(),
    price: (json['price'] as num?)?.toDouble(),
    writable: (json['writable'] as bool?) ?? false,
  );
}

class SalesDocListItem {
  const SalesDocListItem({
    required this.id,
    this.billNo,
    this.billDate,
    this.clientId,
    this.warehouseId,
    this.currencyId,
    this.outType,
    this.totalLocal,
    this.status,
    this.closed = false,
    this.stopped = false,
    this.arPosted = false,
    this.legacyId,
    this.deliverDate,
    this.delayWarning = false,
    this.rejected = false,
    this.priceMasked = false,
    this.writable = false,
    this.canReject = false,
    this.sellerName,
    this.sellerId,
  });

  final String id;
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? warehouseId;
  final String? currencyId;
  final String? outType;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final bool stopped;
  final bool arPosted;
  final int? legacyId;
  final String? deliverDate; // 订货单交货日期
  final bool delayWarning; // 延期预警：已审未结案且距交货 ≤3 天（后端派生）
  final bool rejected; // 仓库驳回（V96，出货单）：备货异常，草稿终态
  final bool priceMasked; // 价格脱敏（SOP §三8）：无 sales_order:price:view 时合计渲染 ***
  final bool writable; // 服务端权威：功能权限 + 负责人范围均允许普通写操作
  final bool canReject; // 服务端权威：仅出货草稿且具备特殊驳回权限

  /// 销售员姓名（服务端按 seller_id 解析；仅销售订单列表下发，生产计划选单展示）。
  /// 其它单据类型列表不下发，保持 null。
  final String? sellerName;

  /// 销售员 id（仅销售订单列表下发；前端跟单员联动回填用）。
  final String? sellerId;

  factory SalesDocListItem.fromJson(Map<String, dynamic> json) =>
      SalesDocListItem(
        id: json['id'] as String,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        clientId: json['clientId'] as String?,
        warehouseId: json['warehouseId'] as String?,
        currencyId: json['currencyId'] as String?,
        outType: json['outType'] as String?,
        totalLocal: (json['totalLocal'] as num?)?.toDouble(),
        status: (json['status'] as num?)?.toInt(),
        closed: (json['closed'] as bool?) ?? false,
        stopped: (json['stopped'] as bool?) ?? false,
        arPosted: (json['arPosted'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        deliverDate: json['deliverDate'] as String?,
        delayWarning: (json['delayWarning'] as bool?) ?? false,
        rejected: (json['rejected'] as bool?) ?? false,
        priceMasked: (json['priceMasked'] as bool?) ?? false,
        writable: (json['writable'] as bool?) ?? false,
        canReject: (json['canReject'] as bool?) ?? false,
        sellerName: json['sellerName'] as String?,
        sellerId: json['sellerId'] as String?,
      );
}

class SalesDocItem {
  const SalesDocItem({
    required this.id,
    this.lineNo,
    this.goodsId,
    this.colorId,
    this.unitId,
    this.unitRate,
    this.qty,
    this.price,
    this.amountOriginal,
    this.amountLocal,
    this.shippedQty,
    this.returnedQty,
    this.flagQty,
    this.discount,
    this.taxAmount,
    this.costAmount,
    this.returnedAmount,
    this.weight,
    this.parcelQty,
    this.cartonCount,
    this.clientNo,
    this.clientModel,
    this.solution,
    this.responsible,
    this.orderItemId,
    this.outItemId,
    this.deliverDate,
    this.sourceDocNo,
    // V66 销售报表补列（明细可录入/系统展示）：
    //   order: machiningPrice/circumference/inboundQty + inNo/outNo（系统字段，只读）
    //   shipment/other_shipment: materialPrice/dieCastPrice/machiningPrice/circumference/discount
    //   return: discount
    this.machiningPrice,
    this.circumference,
    this.inboundQty,
    this.inNo,
    this.outNo,
    this.materialPrice,
    this.dieCastPrice,
    this.remark,
    // V90 业务链（订货行）：可发/已排/已产 + 链路状态（系统回写，只读）
    this.reservedQty,
    this.plannedQty,
    this.producedQty,
    this.chainStatus,
    // 报价转入（SOP §三1）：来源报价行单价（价格留痕比对，系统回联填充，只读）
    this.quotePrice,
    // V178 稀缺仲裁：订单行优先级 1急单/2普通/3现货(默认)；只读展示，设急单走独立权限点
    this.priority,
  });

  final String? id;
  final int? lineNo;
  final String? goodsId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
  final double? qty;
  final double? price;
  final double? amountOriginal;
  final double? amountLocal;
  final double? shippedQty;
  final double? returnedQty;
  final double? flagQty;
  final double? discount;
  final double? taxAmount;
  final double? costAmount;
  final double? returnedAmount;
  final double? weight;
  final double? parcelQty;
  final double? cartonCount;
  final String? clientNo;
  final String? clientModel;
  final String? solution;
  final String? responsible;
  final String? orderItemId;
  final String? outItemId;
  final String? deliverDate;
  final String? sourceDocNo;
  // V66 补列字段（详见构造函数注释）
  final double? machiningPrice;
  final double? circumference;
  final double? inboundQty;
  final String? inNo;
  final String? outNo;
  final double? materialPrice;
  final double? dieCastPrice;
  final String? remark;
  // V90 业务链字段（详见构造函数注释）
  final double? reservedQty;
  final double? plannedQty;
  final double? producedQty;
  final int? chainStatus;

  /// 报价转入：来源报价行单价（只读，价格比对用；非转入单为 null）
  final double? quotePrice;

  /// V178 订单行优先级：1急单/2普通/3现货(默认/null)。仅稀缺让单决策与排序用，不自动抢占。
  final int? priority;

  factory SalesDocItem.fromJson(Map<String, dynamic> json) => SalesDocItem(
    id: json['id'] as String?,
    lineNo: (json['lineNo'] as num?)?.toInt(),
    goodsId: json['goodsId'] as String?,
    colorId: json['colorId'] as String?,
    unitId: json['unitId'] as String?,
    unitRate: (json['unitRate'] as num?)?.toDouble(),
    qty: (json['qty'] as num?)?.toDouble(),
    price: (json['price'] as num?)?.toDouble(),
    amountOriginal: (json['amountOriginal'] as num?)?.toDouble(),
    amountLocal: (json['amountLocal'] as num?)?.toDouble(),
    shippedQty: (json['shippedQty'] as num?)?.toDouble(),
    returnedQty: (json['returnedQty'] as num?)?.toDouble(),
    flagQty: (json['flagQty'] as num?)?.toDouble(),
    discount: (json['discount'] as num?)?.toDouble(),
    taxAmount: (json['taxAmount'] as num?)?.toDouble(),
    costAmount: (json['costAmount'] as num?)?.toDouble(),
    returnedAmount: (json['returnedAmount'] as num?)?.toDouble(),
    weight: (json['weight'] as num?)?.toDouble(),
    parcelQty: (json['parcelQty'] as num?)?.toDouble(),
    cartonCount: (json['cartonCount'] as num?)?.toDouble(),
    clientNo: json['clientNo'] as String?,
    clientModel: json['clientModel'] as String?,
    solution: json['solution'] as String?,
    responsible: json['responsible'] as String?,
    orderItemId: json['orderItemId'] as String?,
    outItemId: json['outItemId'] as String?,
    deliverDate: json['deliverDate'] as String?,
    sourceDocNo: json['sourceDocNo'] as String?,
    machiningPrice: (json['machiningPrice'] as num?)?.toDouble(),
    circumference: (json['circumference'] as num?)?.toDouble(),
    inboundQty: (json['inboundQty'] as num?)?.toDouble(),
    inNo: json['inNo'] as String?,
    outNo: json['outNo'] as String?,
    materialPrice: (json['materialPrice'] as num?)?.toDouble(),
    dieCastPrice: (json['dieCastPrice'] as num?)?.toDouble(),
    remark: json['remark'] as String?,
    reservedQty: (json['reservedQty'] as num?)?.toDouble(),
    plannedQty: (json['plannedQty'] as num?)?.toDouble(),
    producedQty: (json['producedQty'] as num?)?.toDouble(),
    chainStatus: (json['chainStatus'] as num?)?.toInt(),
    quotePrice: (json['quotePrice'] as num?)?.toDouble(),
    priority: (json['priority'] as num?)?.toInt(),
  );
}

/// 稀缺库存占用视图（GET /reservations/scarce；V178）：某货品+颜色的生效预留 + 订单上下文 + 持有逾期。
/// 供主管"稀缺让单"面板判断让谁、让多少（按优先级升序、创建时间升序返回）。
class ScarceReservation {
  const ScarceReservation({
    this.reservationId,
    this.orderItemId,
    this.orderId,
    this.orderNo,
    this.goodsCode,
    this.clientId,
    this.clientName,
    this.priority,
    this.deliverDate,
    this.reservedQty,
    this.holdUntil,
    this.overdueDays,
  });

  final String? reservationId;
  final String? orderItemId;
  final String? orderId;
  final String? orderNo;
  final String? goodsCode;
  final String? clientId;
  final String? clientName;
  /// 1急单/2普通/3现货。
  final int? priority;
  final String? deliverDate;
  /// 生效预留量（行单位）。
  final double? reservedQty;
  /// 持有截止（可空，null=用默认交货日+宽限）。
  final String? holdUntil;
  /// 持有已逾期天数（截止已过且未发完；未逾期/不适用为 null）。
  final int? overdueDays;

  factory ScarceReservation.fromJson(Map<String, dynamic> json) =>
      ScarceReservation(
        reservationId: json['reservationId'] as String?,
        orderItemId: json['orderItemId'] as String?,
        orderId: json['orderId'] as String?,
        orderNo: json['orderNo'] as String?,
        goodsCode: json['goodsCode'] as String?,
        clientId: json['clientId'] as String?,
        clientName: json['clientName'] as String?,
        priority: (json['priority'] as num?)?.toInt(),
        deliverDate: json['deliverDate'] as String?,
        reservedQty: (json['reservedQty'] as num?)?.toDouble(),
        holdUntil: json['holdUntil'] as String?,
        overdueDays: (json['overdueDays'] as num?)?.toInt(),
      );
}

class SalesDocDetail {
  const SalesDocDetail({
    required this.id,
    this.legacyId,
    this.billNo,
    this.billDate,
    this.clientId,
    this.warehouseId,
    this.currencyId,
    this.exchangeRate,
    this.taxRate,
    this.paymentStyleId,
    this.sellerId,
    this.senderId,
    this.makerId,
    this.approverId,
    this.makerName,
    this.createdAt,
    this.validUntil,
    this.deliverDate,
    this.contractNo,
    this.linkPhone,
    this.signAddr,
    this.shipAddr,
    this.deposit,
    this.parcelCount,
    this.printCount,
    this.lastDate,
    this.outType,
    this.remark,
    this.totalOriginal,
    this.totalLocal,
    this.status,
    this.closed = false,
    this.stopped = false,
    this.arPosted = false,
    this.sourceDocNo,
    this.sourceQuoteId,
    this.items = const [],
    this.rejected = false,
    this.rejectReason,
    this.financeAudit,
    this.financeAuditedAt,
    this.priceMasked = false,
    this.writable = false,
    this.canReject = false,
  });

  final String id;
  final int? legacyId;
  final String? billNo;
  final String? billDate;
  final String? clientId;
  final String? warehouseId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;
  final int? paymentStyleId;
  final String? sellerId;
  final String? senderId;
  final String? makerId;
  final String? approverId;

  /// 制单员姓名（服务端解析；只读展示，不可修改）
  final String? makerName;

  /// 制单时间 ISO（审计 created_at，创建后不可变）
  final String? createdAt;
  final String? validUntil;
  final String? deliverDate;
  final String? contractNo;
  final String? linkPhone;
  final String? signAddr;
  final String? shipAddr;
  final double? deposit;
  final int? parcelCount;
  final int? printCount;
  final String? lastDate; // OffsetDateTime 后端 → ISO 字符串
  final String? outType;
  final String? remark;
  final double? totalOriginal;
  final double? totalLocal;
  final int? status;
  final bool closed;
  final bool stopped;
  final bool arPosted;
  final String? sourceDocNo;

  /// 来源报价单 ID（报价转入的订单详情由后端回联填充；用于跳转报价详情）
  final String? sourceQuoteId;
  final List<SalesDocItem> items;
  final bool rejected; // 仓库驳回（V96，出货单）
  final String? rejectReason;

  /// C6 财务发货审核：0 未审 / 1 已审发货（出货单）。
  final int? financeAudit;
  final String? financeAuditedAt;

  /// 价格脱敏（SOP §三8）：无 sales_order:price:view 时价格族字段渲染 ***
  final bool priceMasked;

  /// 服务端能力字段；前端权限常量只能控制入口，不能替代对象负责人范围。
  final bool writable;
  final bool canReject;

  factory SalesDocDetail.fromJson(Map<String, dynamic> json) => SalesDocDetail(
    id: json['id'] as String,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    billNo: json['billNo'] as String?,
    billDate: json['billDate'] as String?,
    clientId: json['clientId'] as String?,
    warehouseId: json['warehouseId'] as String?,
    currencyId: json['currencyId'] as String?,
    exchangeRate: (json['exchangeRate'] as num?)?.toDouble(),
    taxRate: (json['taxRate'] as num?)?.toDouble(),
    paymentStyleId: (json['paymentStyleId'] as num?)?.toInt(),
    sellerId: json['sellerId'] as String?,
    senderId: json['senderId'] as String?,
    makerId: json['makerId'] as String?,
    makerName: json['makerName'] as String?,
    createdAt: json['createdAt'] as String?,
    approverId: json['approverId'] as String?,
    validUntil: json['validUntil'] as String?,
    deliverDate: json['deliverDate'] as String?,
    contractNo: json['contractNo'] as String?,
    linkPhone: json['linkPhone'] as String?,
    signAddr: json['signAddr'] as String?,
    shipAddr: json['shipAddr'] as String?,
    deposit: (json['deposit'] as num?)?.toDouble(),
    parcelCount: (json['parcelCount'] as num?)?.toInt(),
    printCount: (json['printCount'] as num?)?.toInt(),
    lastDate: json['lastDate'] as String?,
    outType: json['outType'] as String?,
    remark: json['remark'] as String?,
    totalOriginal: (json['totalOriginal'] as num?)?.toDouble(),
    totalLocal: (json['totalLocal'] as num?)?.toDouble(),
    status: (json['status'] as num?)?.toInt(),
    closed: (json['closed'] as bool?) ?? false,
    stopped: (json['stopped'] as bool?) ?? false,
    arPosted: (json['arPosted'] as bool?) ?? false,
    sourceDocNo: json['sourceDocNo'] as String?,
    sourceQuoteId: json['sourceQuoteId'] as String?,
    items:
        (json['items'] as List?)
            ?.map((e) => SalesDocItem.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
    rejected: (json['rejected'] as bool?) ?? false,
    rejectReason: json['rejectReason'] as String?,
    financeAudit: (json['financeAudit'] as num?)?.toInt(),
    financeAuditedAt: json['financeAuditedAt'] as String?,
    priceMasked: (json['priceMasked'] as bool?) ?? false,
    writable: (json['writable'] as bool?) ?? false,
    canReject: (json['canReject'] as bool?) ?? false,
  );
}

/// 订单行排产进度（GET /api/sales/orders/{id}/plan-progress）。
/// 销售端看链路另一端：订货/可发/已排/已产/已发 + 关联生产计划溯源。
class OrderPlanProgressLine {
  const OrderPlanProgressLine({
    required this.orderItemId,
    this.lineNo,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorName,
    this.unitName,
    this.qty,
    this.reservedQty,
    this.plannedQty,
    this.producedQty,
    this.shippedQty,
    this.chainStatus,
    this.links = const [],
  });
  final String orderItemId;
  final int? lineNo;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorName;
  final String? unitName;
  final double? qty;
  final double? reservedQty;
  final double? plannedQty;
  final double? producedQty;
  final double? shippedQty;
  final int? chainStatus;
  final List<OrderPlanLink> links;

  factory OrderPlanProgressLine.fromJson(Map<String, dynamic> j) =>
      OrderPlanProgressLine(
        orderItemId: j['orderItemId'] as String,
        lineNo: (j['lineNo'] as num?)?.toInt(),
        goodsCode: j['goodsCode'] as String?,
        goodsName: j['goodsName'] as String?,
        spec: j['spec'] as String?,
        colorName: j['colorName'] as String?,
        unitName: j['unitName'] as String?,
        qty: (j['qty'] as num?)?.toDouble(),
        reservedQty: (j['reservedQty'] as num?)?.toDouble(),
        plannedQty: (j['plannedQty'] as num?)?.toDouble(),
        producedQty: (j['producedQty'] as num?)?.toDouble(),
        shippedQty: (j['shippedQty'] as num?)?.toDouble(),
        chainStatus: (j['chainStatus'] as num?)?.toInt(),
        links: [
          for (final l in (j['links'] as List? ?? const []))
            OrderPlanLink.fromJson(l as Map<String, dynamic>),
        ],
      );
}

/// 关联生产计划（plan_order_item_links 溯源）。
class OrderPlanLink {
  const OrderPlanLink({
    required this.planId,
    this.planNo,
    this.planStatus,
    this.planClosed = false,
    this.billDate,
    this.allocatedQty,
    this.producedQty,
    this.inboundQty,
    this.executionSegments = const [],
  });
  final String planId;
  final String? planNo;
  final int? planStatus; // 0草稿 1已审 -1红冲
  final bool planClosed;
  final String? billDate;
  final double? allocatedQty;
  final double? producedQty;
  final double? inboundQty;
  final List<OrderExecutionSegmentProgress> executionSegments;

  factory OrderPlanLink.fromJson(Map<String, dynamic> j) => OrderPlanLink(
    planId: j['planId'] as String,
    planNo: j['planNo'] as String?,
    planStatus: (j['planStatus'] as num?)?.toInt(),
    planClosed: j['planClosed'] == true,
    billDate: j['billDate'] as String?,
    allocatedQty: (j['allocatedQty'] as num?)?.toDouble(),
    producedQty: (j['producedQty'] as num?)?.toDouble(),
    inboundQty: (j['inboundQty'] as num?)?.toDouble(),
    executionSegments: [
      for (final segment in (j['executionSegments'] as List? ?? const []))
        OrderExecutionSegmentProgress.fromJson(
          segment as Map<String, dynamic>,
        ),
    ],
  );
}

class OrderExecutionSegmentProgress {
  const OrderExecutionSegmentProgress({
    required this.executionSegmentId,
    this.segmentCode,
    this.status,
    this.allocatedQty,
    this.reportedQty,
    this.inboundQty,
    this.workshopName,
    this.teamName,
    this.planBeginDate,
    this.planEndDate,
    this.actualStartAt,
    this.delayed = false,
    this.delayReason,
  });

  final String executionSegmentId;
  final String? segmentCode;
  final String? status;
  final double? allocatedQty;
  final double? reportedQty;
  final double? inboundQty;
  final String? workshopName;
  final String? teamName;
  final String? planBeginDate;
  final String? planEndDate;
  final String? actualStartAt;
  final bool delayed;
  final String? delayReason;

  factory OrderExecutionSegmentProgress.fromJson(Map<String, dynamic> json) =>
      OrderExecutionSegmentProgress(
        executionSegmentId: json['executionSegmentId'] as String,
        segmentCode: json['segmentCode'] as String?,
        status: json['status'] as String?,
        allocatedQty: (json['allocatedQty'] as num?)?.toDouble(),
        reportedQty: (json['reportedQty'] as num?)?.toDouble(),
        inboundQty: (json['inboundQty'] as num?)?.toDouble(),
        workshopName: json['workshopName'] as String?,
        teamName: json['teamName'] as String?,
        planBeginDate: json['planBeginDate'] as String?,
        planEndDate: json['planEndDate'] as String?,
        actualStartAt: json['actualStartAt'] as String?,
        delayed: json['delayed'] == true,
        delayReason: json['delayReason'] as String?,
      );
}
