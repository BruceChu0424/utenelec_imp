import '../formatters/exact_decimal.dart';

// Read-only production evidence. Missing facts stay null; issued quantities and
// period allocations never become measured product consumption.
class TraceGoodsIdentity {
  TraceGoodsIdentity.fromJson(Map<String, dynamic> j)
    : goodsId = _text(j['goodsId']),
      goodsCode = _text(j['goodsCode']),
      goodsName = _text(j['goodsName']),
      colorName = _text(j['colorName']),
      unitName = _text(j['unitName']);
  final String? goodsId, goodsCode, goodsName, colorName, unitName;
}

class TraceDocument {
  TraceDocument.fromJson(Map<String, dynamic> j)
    : id = _text(j['id']),
      billNo = _text(j['billNo']),
      billDate = _text(j['billDate']),
      docType = _text(j['docType']);
  final String? id, billNo, billDate, docType;
}

class TraceProductionReport {
  TraceProductionReport.fromJson(Map<String, dynamic> j)
    : id = _text(j['id']),
      billNo = _text(j['billNo']),
      billDate = _text(j['billDate']),
      productQty = financeExactDecimal(j['productQty']),
      unitName = _text(j['unitName']),
      workers = _maps(
        j['workers'],
      ).map((w) => _text(w['name'])).nonNulls.toList();
  final String? id, billNo, billDate, unitName;
  final String? productQty;
  final List<String> workers;
}

class TraceReceiptSource {
  TraceReceiptSource.fromJson(Map<String, dynamic> j)
    : id = _text(j['id']),
      billNo = _text(j['billNo']),
      billDate = _text(j['billDate']),
      supplierName = _text(j['supplierName']),
      sourceBasis = _text(j['sourceBasis']),
      sourceDocType = _text(j['sourceDocType']),
      sourceDocCode = _text(j['sourceDocCode']),
      qty = financeExactDecimal(j['qty']);
  final String? id,
      billNo,
      billDate,
      supplierName,
      sourceBasis,
      sourceDocType,
      sourceDocCode;
  final String? qty;
}

class GoodsProductionTraceRow {
  GoodsProductionTraceRow.fromJson(Map<String, dynamic> j)
    : id = j['id'].toString(),
      kind = j['kind']?.toString() ?? 'ORDER',
      quantityBasis = _text(j['quantityBasis']),
      planId = _text(j['planId']),
      planNo = _text(j['planNo']),
      segmentCode = _text(j['segmentCode']),
      workshopName = _text(j['workshopName']),
      product = TraceGoodsIdentity.fromJson(_map(j['product'])),
      material = TraceGoodsIdentity.fromJson(_map(j['material'])),
      issuedQty = financeExactDecimal(j['issuedQty']),
      returnedQty = financeExactDecimal(j['returnedQty']),
      consumedQty = financeExactDecimal(j['consumedQty']),
      lossQty = financeExactDecimal(j['lossQty']),
      allocatedQty = financeExactDecimal(j['allocatedQty']),
      drawDocuments = _maps(
        j['drawDocuments'],
      ).map(TraceDocument.fromJson).toList(),
      reports = _maps(
        j['reports'],
      ).map(TraceProductionReport.fromJson).toList(),
      receiptSources = _maps(
        j['receiptSources'],
      ).map(TraceReceiptSource.fromJson).toList();
  final String id, kind;
  final String? quantityBasis, planId, planNo, segmentCode, workshopName;
  final TraceGoodsIdentity product, material;
  final String? issuedQty, returnedQty, consumedQty, lossQty, allocatedQty;
  final List<TraceDocument> drawDocuments;
  final List<TraceProductionReport> reports;
  final List<TraceReceiptSource> receiptSources;
  bool get isPeriodic => kind == 'PERIODIC';
}

Map<String, dynamic> _map(Object? value) => value is Map<dynamic, dynamic>
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : {};
List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map<dynamic, dynamic>>().map(_map).toList()
    : [];
String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
