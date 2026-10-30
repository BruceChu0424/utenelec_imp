import 'dart:convert';

import '../formatters/exact_decimal.dart';

enum ProcurementOrderPrintKind {
  purchase('采购单', '采 购 单', 'purchase'),
  subcontract('委外订货单', '委 外 订 货 单', 'subcontract');

  const ProcurementOrderPrintKind(this.label, this.paperTitle, this.module);
  final String label, paperTitle, module;
  String get endpoint => '/$module/orders';
  String get workerKind => '$module-order-bundle';
}

/// A single server-authorized snapshot shared by the paper preview and PDF.
class ProcurementOrderPrintDocument {
  ProcurementOrderPrintDocument.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      contentDigest = json['contentDigest'] as String?,
      billNo = _text(json['billNo']),
      billDate = _text(json['billDate']),
      deliverDate = _text(json['deliverDate']),
      companyName = _text(json['companyName']),
      companyPhone = _text(json['companyPhone']),
      supplierName = _text(json['supplierName']),
      supplierContact = _text(json['supplierContact']),
      supplierPhone = _text(json['supplierPhone']),
      deliveryPlace = _text(json['deliveryPlace']),
      priceMasked = json['priceMasked'] == true,
      currencyName = json['priceMasked'] == true
          ? ''
          : _text(json['currencyName']),
      currencyCode = json['priceMasked'] == true
          ? ''
          : _text(json['currencyCode']),
      settlementMethod = json['priceMasked'] == true
          ? ''
          : _text(json['settlementMethod']),
      totalOriginal = json['priceMasked'] == true
          ? null
          : financeExactDecimal(json['totalOriginal']),
      remark = _text(json['remark']),
      makerName = _text(json['makerName']),
      reviewerName = _financeApproved(json) ? _text(json['reviewerName']) : '',
      financeApproved = _financeApproved(json),
      statusLabel = _text(json['statusLabel']),
      lines = (json['lines'] as List)
          .map(
            (line) => ProcurementOrderPrintLine.fromJson(
              (line as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
      materials = (json['materials'] as List? ?? const [])
          .map(
            (line) => ProcurementOrderMaterialLine.fromJson(
              (line as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false);

  final String id, billNo, billDate, deliverDate, companyName, companyPhone;
  final String? contentDigest;
  final String supplierName, supplierContact, supplierPhone, deliveryPlace;
  final String currencyName, currencyCode, settlementMethod, remark;
  final String makerName, reviewerName, statusLabel;
  final String? totalOriginal;
  final bool priceMasked;
  final bool financeApproved;
  final List<ProcurementOrderPrintLine> lines;

  /// 委外订货单的直属物料行(2026-10-30 用户口径: 单上同时给成品与物料及对应关系);
  /// 采购单恒为空。
  final List<ProcurementOrderMaterialLine> materials;

  String get signature => jsonEncode([
    id,
    billNo,
    billDate,
    deliverDate,
    companyName,
    companyPhone,
    supplierName,
    supplierContact,
    supplierPhone,
    deliveryPlace,
    currencyName,
    currencyCode,
    settlementMethod,
    totalOriginal,
    priceMasked,
    remark,
    makerName,
    reviewerName,
    statusLabel,
    financeApproved,
    lines.map((line) => line.id).toList(growable: false),
    rows,
    materialRows,
  ]);

  String get amountLabel => priceMasked
      ? '***'
      : '${financeExactMoneyDisplay(totalOriginal)} ${_shown(currencyName)}';
  String get capitalLabel => priceMasked
      ? '***'
      : currencyCode.toUpperCase() == 'CNY' || currencyName.contains('人民币')
      ? procurementOrderRmbCapital(totalOriginal)
      : '—';

  static const headers = [
    '序号',
    '物料编号',
    '货品名称',
    '型号',
    '规格',
    '颜色',
    '单位',
    '数量',
    '材质',
    '备注',
  ];
  static const widths = [
    6.0,
    14.0,
    25.0,
    11.0,
    16.0,
    9.0,
    7.0,
    13.0,
    12.0,
    21.0,
  ];
  List<List<String>> get rows => [
    for (var index = 0; index < lines.length; index++)
      [
        '${index + 1}',
        _shown(lines[index].goodsCode),
        _shown(lines[index].goodsName),
        _shown(lines[index].model),
        _shown(lines[index].spec),
        _shown(lines[index].colorName),
        _shown(lines[index].unitName),
        _shown(financeExactTrimmed(lines[index].physicalQty)),
        _shown(lines[index].material),
        _shown(lines[index].printRemark(deliverDate)),
      ],
  ];

  /// 委外物料(我方供料)表: 「第 n 行」指向上方成品表的行号(对应关系)。
  static const materialHeaders = [
    '序号',
    '物料编号',
    '物料名称',
    '颜色',
    '单位',
    '单耗',
    '需发量',
    '所属成品',
  ];
  static const materialWidths = [
    6.0,
    14.0,
    24.0,
    10.0,
    8.0,
    10.0,
    11.0,
    17.0,
  ];
  List<List<String>> get materialRows => [
    for (var index = 0; index < materials.length; index++)
      [
        '${index + 1}',
        _shown(materials[index].goodsCode),
        _shown(materials[index].goodsName),
        _shown(materials[index].colorName),
        _shown(materials[index].unitName),
        _shown(financeExactTrimmed(materials[index].bomUnitQty)),
        _shown(financeExactTrimmed(materials[index].requiredQty)),
        _shown(materials[index].ownerLabel),
      ],
  ];
}

/// 委外订货单直属物料行; orderLineNo 指向成品行(对应关系)。
class ProcurementOrderMaterialLine {
  ProcurementOrderMaterialLine.fromJson(Map<String, dynamic> json)
    : orderItemId = json['orderItemId'] as String,
      orderLineNo = (json['orderLineNo'] as num?)?.toInt(),
      goodsCode = _text(json['goodsCode']),
      goodsName = _text(json['goodsName']),
      colorName = _text(json['colorName']),
      unitName = _text(json['unitName']),
      bomUnitQty = financeExactDecimal(json['bomUnitQty']),
      requiredQty = financeExactDecimal(json['requiredQty']);

  final String orderItemId;
  final int? orderLineNo;
  final String goodsCode, goodsName, colorName, unitName;

  /// 含损耗单耗(物料单位/成品单位)与需发总量(物料单位), 精确十进制文本。
  final String? bomUnitQty, requiredQty;

  /// 对应关系文案: 「第 n 行」指向成品表行号。
  String get ownerLabel => orderLineNo == null ? '—' : '第 $orderLineNo 行';
}

class ProcurementOrderPrintLine {
  ProcurementOrderPrintLine.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      goodsCode = _text(json['goodsCode']),
      goodsName = _text(json['goodsName']),
      model = _text(json['model']),
      spec = _text(json['spec']),
      colorName = _text(json['colorName']),
      unitName = _text(json['unitName']),
      physicalQty = financeExactDecimal(json['physicalQty']),
      chargedQty = financeExactDecimal(json['chargedQty']),
      giftQty = financeExactDecimal(json['giftQty']),
      material = _text(json['material']),
      remark = _text(json['remark']),
      deliverDate = _text(json['deliverDate']);

  final String id, goodsCode, goodsName, model, spec, colorName, unitName;
  final String material, remark, deliverDate;
  final String? physicalQty, chargedQty, giftQty;

  String printRemark(String orderDeliverDate) => [
    if (remark.isNotEmpty) remark,
    if ((financeExactDecimalUnits(giftQty) ?? BigInt.zero) > BigInt.zero)
      '计价 ${financeExactTrimmed(chargedQty) ?? '—'}；赠品 ${financeExactTrimmed(giftQty)}',
    if (deliverDate.isNotEmpty && deliverDate != orderDeliverDate)
      '交期 $deliverDate',
  ].join('\n');
}

String _text(Object? value) => value?.toString().trim() ?? '';
bool _financeApproved(Map<String, dynamic> json) =>
    json.containsKey('financeApproved')
    ? json['financeApproved'] == true
    : json['statusLabel'] == '财务已通过';
String _shown(String? value) => value == null || value.isEmpty ? '—' : value;

/// Money stays decimal text; sub-cent amounts are never silently rounded.
String procurementOrderRmbCapital(String? exact) {
  final rounded = financeExactMoneyDisplay(exact);
  if (!RegExp(r'^\d+\.\d{2}$').hasMatch(rounded)) {
    return financeExactDecimal(exact) == null ? '—' : '金额含分以下小数，详见小写合计';
  }
  final parts = rounded.split('.');
  final yuan = BigInt.parse(parts[0]);
  const digits = '零壹贰叁肆伍陆柒捌玖';
  const groups = ['', '万', '亿', '万亿', '亿亿', '万亿亿', '亿亿亿'];
  const units = ['', '拾', '佰', '仟'];
  String four(int value) {
    final out = StringBuffer();
    var zero = false;
    for (var index = 3; index >= 0; index--) {
      var power = 1;
      for (var p = 0; p < index; p++) {
        power *= 10;
      }
      final digit = value ~/ power % 10;
      if (digit == 0) {
        if (out.isNotEmpty) zero = true;
        continue;
      }
      if (zero) out.write('零');
      out.write('${digits[digit]}${units[index]}');
      zero = false;
    }
    return out.toString();
  }

  final segments = <int>[];
  var rest = yuan;
  while (rest > BigInt.zero) {
    segments.add((rest % BigInt.from(10000)).toInt());
    rest ~/= BigInt.from(10000);
  }
  if (segments.length > groups.length) return '—';
  final out = StringBuffer('人民币');
  var previous = false;
  var skipped = false;
  if (segments.isEmpty) out.write('零');
  for (var index = segments.length - 1; index >= 0; index--) {
    final segment = segments[index];
    if (segment == 0) {
      skipped = true;
      continue;
    }
    if (previous && (skipped || segment < 1000)) out.write('零');
    out.write('${four(segment)}${groups[index]}');
    previous = true;
    skipped = false;
  }
  out.write('元');
  final jiao = int.parse(parts[1][0]), fen = int.parse(parts[1][1]);
  if (jiao == 0 && fen == 0) {
    out.write('整');
  } else {
    if (jiao > 0) out.write('${digits[jiao]}角');
    if (jiao == 0 && fen > 0) out.write('零');
    if (fen > 0) out.write('${digits[fen]}分');
  }
  return out.toString();
}
