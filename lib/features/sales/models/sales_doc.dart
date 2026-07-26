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
      orElse: () => SalesDocType.quote);
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
    this.remark,
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
  final String? remark;

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
        remark: json['remark'] as String?,
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
    this.items = const [],
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
  final List<SalesDocItem> items;

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
        items: (json['items'] as List?)
                ?.map((e) => SalesDocItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}
