import '../formatters/exact_decimal.dart';
import '../models/paged_result.dart';
import 'production_trace_models.dart';

/// A server-resolved identity. Display numbers are never used as foreign keys.
class MaterialTraceSubject {
  const MaterialTraceSubject({
    required this.type,
    required this.id,
    required this.code,
    required this.label,
    this.documentDate,
    this.status,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.basis,
    this.traceable = true,
    this.reason,
  });

  factory MaterialTraceSubject.fromJson(Map<String, dynamic> json) =>
      MaterialTraceSubject(
        type: json['type']?.toString() ?? '',
        id: json['id']?.toString() ?? '',
        code: json['code']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        documentDate: _text(json['documentDate']),
        status: _text(json['status']),
        goodsId: _text(json['goodsId']),
        goodsCode: _text(json['goodsCode']),
        goodsName: _text(json['goodsName']),
        basis: _text(json['basis']),
        traceable: json['traceable'] != false,
        reason: _text(json['reason']),
      );

  final String type, id, code, label;
  final String? documentDate, status, goodsId, goodsCode, goodsName, basis;
  final bool traceable;
  final String? reason;

  bool get isGoods => type == 'GOODS';
  String get displayName => label.isNotEmpty ? label : code;
  (String, String) get identity => (type, id);
}

/// A source document, receipt or batch remains useful before production starts.
class MaterialTraceSource {
  MaterialTraceSource.fromJson(Map<String, dynamic> json)
    : type = _text(json['type']),
      id = _text(json['id']),
      itemId = _text(json['itemId']),
      code = _text(json['code']),
      date = _text(json['date']),
      goods = TraceGoodsIdentity.fromJson(_map(json['goods'])),
      qty = financeExactDecimal(json['qty']),
      unitName = _text(json['unitName']),
      status = _text(json['status']),
      basis = _text(json['basis']),
      note = _text(json['note']),
      warehouseName = _text(json['warehouseName']),
      supplierName = _text(json['supplierName']),
      relatedProduct = json['relatedProduct'] is Map
          ? TraceGoodsIdentity.fromJson(_map(json['relatedProduct']))
          : null,
      relatedOrderId = _text(json['relatedOrderId']),
      relatedOrderCode = _text(json['relatedOrderCode']),
      docType = _text(json['docType']);

  final String? type, id, code, date, qty, unitName, status, basis, note;
  final String? itemId;
  final String? warehouseName, supplierName;
  final TraceGoodsIdentity goods;
  final TraceGoodsIdentity? relatedProduct;
  final String? relatedOrderId, relatedOrderCode;
  final String? docType;
}

class MaterialTraceResult {
  MaterialTraceResult.fromJson(Map<String, dynamic> json)
    : page = PagedResult.fromJson(json, GoodsProductionTraceRow.fromJson),
      subject = json['subject'] is Map
          ? MaterialTraceSubject.fromJson(_map(json['subject']))
          : null,
      sources = _maps(
        json['sources'],
      ).map(MaterialTraceSource.fromJson).toList(),
      coverageNotes = json['coverageNotes'] is List
          ? (json['coverageNotes'] as List)
                .map(_text)
                .nonNulls
                .toList(growable: false)
          : const [],
      sourceTotal = int.tryParse(json['sourceTotal']?.toString() ?? ''),
      sourcesTruncated = json['sourcesTruncated'] == true;

  final PagedResult<GoodsProductionTraceRow> page;
  final MaterialTraceSubject? subject;
  final List<MaterialTraceSource> sources;
  final List<String> coverageNotes;
  final int? sourceTotal;
  final bool sourcesTruncated;
}

Map<String, dynamic> _map(Object? value) => value is Map<dynamic, dynamic>
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : const {};

Iterable<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map<dynamic, dynamic>>().map(_map)
    : const [];

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String materialTraceStatusLabel(String status) => switch (status) {
  'DRAFT' => '草稿',
  'APPROVED' => '已审核',
  'REVERSED' => '已反冲',
  'CANCELED' || 'CANCELLED' => '已取消',
  'ACTIVE' => '有效',
  'DELETED' => '已删除',
  'PENDING' => '待处理',
  'UNKNOWN' => '状态未留存',
  _ => status,
};

String materialTraceBasisLabel(String basis) => switch (basis) {
  'ORDERED_QUANTITY' => '订货数量',
  'RECEIPT_QUANTITY' => '收货记录数量',
  'STOCK_DOCUMENT_QUANTITY' => '库存单据数量',
  'PRODUCTION_OUTPUT' => '报工产出记录',
  'ACTUAL_MATERIAL_ISSUE' => '实际领料记录',
  'FROZEN_BOM_ESTIMATE' => '按冻结 BOM 核销（估算）',
  _ => basis,
};

String materialTraceSubjectTypeLabel(String type) => switch (type) {
  'GOODS' => '货品',
  'PURCHASE_ORDER' => '采购订货',
  'PURCHASE_RECEIPT' => '采购收货',
  'SUBCONTRACT_ORDER' => '委外订货',
  'SUBCONTRACT_RECEIPT' => '委外回货',
  'SUBCONTRACT_MATERIAL_ISSUE' => '委外发料',
  'SUBCONTRACT_MATERIAL_CONSUMPTION' => '委外回货核销',
  'PRODUCTION_PLAN' => '生产计划',
  'PRODUCTION_REPORT' => '生产报工',
  'STOCK_DOC' => '出入库单',
  'PRODUCTION_OUTPUT_LOT' => '生产批次',
  _ => '追溯记录',
};
