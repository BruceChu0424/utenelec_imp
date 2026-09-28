// 销售客户文件识别(ADR-134)的客户端模型: 与服务端作业结果 JSON(SPEC §5.9,
// ai_jobs.result, kind = SALES_DOCUMENT_INTAKE)一一对应。
//
// 解析一律防御式: 字段缺失/类型不符时取空值而不是抛错(结果来自 AI + 规则, 服务端
// 版本升级也可能新增字段); 金额/折扣统一保存为十进制文本, 不经二进制浮点换算,
// 保存时原样随单据提交, 由服务端做最终校验(ADR-112)。
library;

import '../../../shared/formatters/exact_decimal.dart';

/// 作业种类(服务端 AiJobHandler.kind)。
const String kSalesIntakeJobKind = 'SALES_DOCUMENT_INTAKE';

/// 识别结果契约版本; 更高版本仍按已知字段解析(向前兼容)。
const int kSalesIntakeSchemaVersion = 2;

/// 服务端逐行定价标记(§5.7)。
abstract final class SalesIntakePricingFlag {
  static const ok = 'OK';
  static const noListPrice = 'NO_LIST_PRICE';
  static const aboveList = 'ABOVE_LIST';
  static const outOfRange = 'OUT_OF_RANGE';
  static const ambiguousCurrency = 'AMBIGUOUS_CURRENCY';
  static const rateMissing = 'RATE_MISSING';
  static const rounded = 'ROUNDED';
}

/// 行警告代码(§5.2 / §5.9)。
abstract final class SalesIntakeWarningCode {
  static const amountMismatch = 'AMOUNT_MISMATCH';
  static const unitNotPcs = 'UNIT_NOT_PCS';
  static const bundleLine = 'BUNDLE_LINE';
  static const duplicateGoods = 'DUPLICATE_GOODS';
  static const noListPrice = 'NO_LIST_PRICE';
  static const aboveList = 'ABOVE_LIST';
}

/// 客户端上可写回客户资料的字段(§5.8, 服务端同样白名单校验)。
const Set<String> kSalesIntakeClientFieldKeys = {
  'nameEn',
  'fullName',
  'linkman',
  'email',
  'phone',
  'mobile',
  'address',
  'taxId',
  'website',
};

enum SalesIntakeLineStatus {
  matched,
  review,
  unmatched;

  static SalesIntakeLineStatus parse(Object? raw) =>
      switch ('${raw ?? ''}'.toUpperCase()) {
        'MATCHED' => SalesIntakeLineStatus.matched,
        'UNMATCHED' => SalesIntakeLineStatus.unmatched,
        _ => SalesIntakeLineStatus.review,
      };
}

enum SalesIntakeConfidence {
  high,
  medium,
  low;

  static SalesIntakeConfidence parse(Object? raw) =>
      switch ('${raw ?? ''}'.toUpperCase()) {
        'HIGH' => SalesIntakeConfidence.high,
        'MEDIUM' => SalesIntakeConfidence.medium,
        _ => SalesIntakeConfidence.low,
      };
}

enum SalesIntakeClientStatus {
  matched,
  review,
  unmatched,
  preset,
  noVisibleClients;

  static SalesIntakeClientStatus parse(Object? raw) =>
      switch ('${raw ?? ''}'.toUpperCase()) {
        'MATCHED' => SalesIntakeClientStatus.matched,
        'PRESET' => SalesIntakeClientStatus.preset,
        'UNMATCHED' => SalesIntakeClientStatus.unmatched,
        'NO_VISIBLE_CLIENTS' => SalesIntakeClientStatus.noVisibleClients,
        _ => SalesIntakeClientStatus.review,
      };

  /// 已经确定客户(自动对上或页面已选), 面板只显示一行。
  bool get resolved =>
      this == SalesIntakeClientStatus.matched ||
      this == SalesIntakeClientStatus.preset;
}

String? _str(Object? raw) {
  if (raw == null) return null;
  final text = '$raw'.trim();
  return text.isEmpty ? null : text;
}

/// 十进制文本: JSON 数字或数字字符串 → 去尾零的规范文本; 非数字返回 null。
String? _decimal(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    if (!raw.isFinite) return null;
    return financeExactTrimmed(raw.toString());
  }
  final text = '$raw'.trim().replaceAll(',', '');
  if (text.isEmpty || double.tryParse(text) == null) return null;
  return financeExactTrimmed(text);
}

int? _int(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

bool _bool(Object? raw) => raw == true || '$raw'.toLowerCase() == 'true';

Map<String, dynamic> _map(Object? raw) =>
    raw is Map ? Map<String, dynamic>.from(raw) : const {};

List<Map<String, dynamic>> _maps(Object? raw) => [
  if (raw is List)
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
];

List<String> _strings(Object? raw) => [
  if (raw is List)
    for (final item in raw) ?_str(item),
];

/// 文件信息 + 其它像明细表的工作表(只提示, 不自动合并)。
class SalesIntakeFileInfo {
  const SalesIntakeFileInfo({
    this.name,
    this.kind,
    this.sheet,
    this.sha256,
    this.otherSheets = const [],
  });

  factory SalesIntakeFileInfo.fromJson(Map<String, dynamic> json) =>
      SalesIntakeFileInfo(
        name: _str(json['name']),
        kind: _str(json['kind']),
        sheet: _str(json['sheet']),
        sha256: _str(json['sha256']),
        otherSheets: [
          for (final sheet in _maps(json['otherSheets']))
            if (_str(sheet['name']) case final name?)
              SalesIntakeOtherSheet(
                name: name,
                lineCount: _int(sheet['lineCount']) ?? 0,
              ),
        ],
      );

  final String? name;
  final String? kind;
  final String? sheet;
  final String? sha256;
  final List<SalesIntakeOtherSheet> otherSheets;
}

class SalesIntakeOtherSheet {
  const SalesIntakeOtherSheet({required this.name, required this.lineCount});

  final String name;
  final int lineCount;
}

/// 表头信息(规则优先, AI 只补空)。
class SalesIntakeHeader {
  const SalesIntakeHeader({
    this.buyerName,
    this.buyerAddress,
    this.contactName,
    this.emails = const [],
    this.phones = const [],
    this.taxId,
    this.docNo,
    this.docDate,
    this.incoterm,
    this.port,
    this.paymentTerms,
    this.remarkSuggestion,
  });

  factory SalesIntakeHeader.fromJson(Map<String, dynamic> json) =>
      SalesIntakeHeader(
        buyerName: _str(json['buyerName']),
        buyerAddress: _str(json['buyerAddress']),
        contactName: _str(json['contactName']),
        emails: _strings(json['emails']),
        phones: _strings(json['phones']),
        taxId: _str(json['taxId']),
        docNo: _str(json['docNo']),
        docDate: _str(json['docDate']),
        incoterm: _str(json['incoterm']),
        port: _str(json['port']),
        paymentTerms: _str(json['paymentTerms']),
        remarkSuggestion: _str(json['remarkSuggestion']),
      );

  final String? buyerName;
  final String? buyerAddress;
  final String? contactName;
  final List<String> emails;
  final List<String> phones;
  final String? taxId;

  /// 客户单号(如 PI 号 "UJ23"), 导入时带到合同号。
  final String? docNo;
  final String? docDate;
  final String? incoterm;
  final String? port;
  final String? paymentTerms;

  /// 服务端拼好的备注建议(贸易条款 + 付款方式)。
  final String? remarkSuggestion;
}

/// 币种: 导入后的单据一律用本位币(标价所用币种), 文件币种只做记录(§5.7)。
class SalesIntakeCurrency {
  const SalesIntakeCurrency({
    this.fileCurrency,
    this.baseCurrencyId,
    this.baseCurrencyName,
    this.financeRate,
    this.rateMissing = false,
  });

  factory SalesIntakeCurrency.fromJson(Map<String, dynamic> json) =>
      SalesIntakeCurrency(
        fileCurrency: _str(json['fileCurrency'])?.toUpperCase(),
        baseCurrencyId: _str(json['baseCurrencyId']),
        baseCurrencyName: _str(json['baseCurrencyName']),
        financeRate: _decimal(json['financeRate']),
        rateMissing: _bool(json['rateMissing']),
      );

  final String? fileCurrency;
  final String? baseCurrencyId;
  final String? baseCurrencyName;

  /// 财务在币种资料里维护的参考汇率(文件币种 → 本位币), 销售不能输入。
  final String? financeRate;
  final bool rateMissing;
}

class SalesIntakeClientCandidate {
  const SalesIntakeClientCandidate({
    required this.clientId,
    this.code,
    this.name,
    this.fullName,
    this.nameEn,
    this.reasons = const [],
  });

  factory SalesIntakeClientCandidate.fromJson(Map<String, dynamic> json) =>
      SalesIntakeClientCandidate(
        clientId: _str(json['clientId']) ?? '',
        code: _str(json['code']),
        name: _str(json['name']),
        fullName: _str(json['fullName']),
        nameEn: _str(json['nameEn']),
        reasons: _strings(json['reasons']),
      );

  final String clientId;
  final String? code;
  final String? name;
  final String? fullName;
  final String? nameEn;

  /// 大白话理由(邮箱一致 / 这些货品该客户都买过 ...); 分数不展示给销售。
  final List<String> reasons;

  String get displayName {
    final base = name ?? fullName ?? nameEn ?? clientId;
    return code == null ? base : '$base($code)';
  }
}

/// 可补进客户资料的一项(§5.6): 当前为空的默认勾选, 与现有值不同的默认不勾。
class SalesIntakeEnrichmentField {
  const SalesIntakeEnrichmentField({
    required this.field,
    required this.label,
    required this.proposed,
    this.current,
    this.defaultChecked = false,
    this.differs = false,
  });

  factory SalesIntakeEnrichmentField.fromJson(Map<String, dynamic> json) =>
      SalesIntakeEnrichmentField(
        field: _str(json['field']) ?? '',
        label: _str(json['label']) ?? _str(json['field']) ?? '',
        proposed: _str(json['proposed']) ?? '',
        current: _str(json['current']),
        defaultChecked: _bool(json['defaultChecked']),
        differs: _bool(json['differs']),
      );

  final String field;
  final String label;
  final String proposed;
  final String? current;
  final bool defaultChecked;
  final bool differs;
}

/// 「用文件信息新建客户」的预填(§5.6, POST /master/clients/from-document)。
class SalesIntakeNewClientProposal {
  const SalesIntakeNewClientProposal({
    this.name,
    this.fullName,
    this.nameEn,
    this.linkman,
    this.email,
    this.phone,
    this.address,
    this.taxId,
    this.placeId,
  });

  factory SalesIntakeNewClientProposal.fromJson(Map<String, dynamic> json) =>
      SalesIntakeNewClientProposal(
        name: _str(json['name']),
        fullName: _str(json['fullName']),
        nameEn: _str(json['nameEn']),
        linkman: _str(json['linkman']),
        email: _str(json['email']),
        phone: _str(json['phone']),
        address: _str(json['address']),
        taxId: _str(json['taxId']),
        placeId: _str(json['placeId']),
      );

  final String? name;
  final String? fullName;
  final String? nameEn;
  final String? linkman;
  final String? email;
  final String? phone;
  final String? address;
  final String? taxId;

  /// 国家/地区(客户资料 place)。
  final String? placeId;

  bool get hasName => (name ?? fullName ?? nameEn)?.trim().isNotEmpty ?? false;

  SalesIntakeNewClientProposal copyWith({String? name}) =>
      SalesIntakeNewClientProposal(
        name: name ?? this.name,
        fullName: fullName,
        nameEn: nameEn,
        linkman: linkman,
        email: email,
        phone: phone,
        address: address,
        taxId: taxId,
        placeId: placeId,
      );

  /// 请求体(服务端 ClientFromDocumentController.Request)。文件里的原文可能超长,
  /// 按服务端各字段长度上限截断, 免得整张新建被 400 挡住(对话框只能改简称)。
  Map<String, dynamic> toJson() => {
    'name': ?_clip(name, 500),
    'fullName': ?_clip(fullName, 200),
    'nameEn': ?_clip(nameEn, 255),
    'linkman': ?_clip(linkman, 100),
    'email': ?_clip(email, 200),
    'phone': ?_clip(phone, 64),
    'address': ?_clip(address, 500),
    'taxId': ?_clip(taxId, 64),
    'placeId': ?_clip(placeId, 64),
  };

  static String? _clip(String? value, int max) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    return text.length <= max ? text : text.substring(0, max).trimRight();
  }
}

class SalesIntakeClientBlock {
  const SalesIntakeClientBlock({
    this.status = SalesIntakeClientStatus.review,
    this.selectedClientId,
    this.candidates = const [],
    this.mismatchWarning,
    this.enrichment = const [],
    this.newClientProposal,
  });

  factory SalesIntakeClientBlock.fromJson(Map<String, dynamic> json) {
    final proposal = json['newClientProposal'];
    return SalesIntakeClientBlock(
      status: SalesIntakeClientStatus.parse(json['status']),
      selectedClientId: _str(json['selectedClientId']),
      candidates: [
        for (final candidate in _maps(json['candidates']))
          if (_str(candidate['clientId']) != null)
            SalesIntakeClientCandidate.fromJson(candidate),
      ],
      mismatchWarning: _str(json['mismatchWarning']),
      enrichment: [
        for (final field in _maps(json['enrichment']))
          if (kSalesIntakeClientFieldKeys.contains(_str(field['field'])) &&
              _str(field['proposed']) != null)
            SalesIntakeEnrichmentField.fromJson(field),
      ],
      newClientProposal: proposal is Map
          ? SalesIntakeNewClientProposal.fromJson(
              Map<String, dynamic>.from(proposal),
            )
          : null,
    );
  }

  final SalesIntakeClientStatus status;
  final String? selectedClientId;
  final List<SalesIntakeClientCandidate> candidates;
  final String? mismatchWarning;
  final List<SalesIntakeEnrichmentField> enrichment;
  final SalesIntakeNewClientProposal? newClientProposal;

  SalesIntakeClientCandidate? candidate(String? clientId) {
    if (clientId == null) return null;
    for (final c in candidates) {
      if (c.clientId == clientId) return c;
    }
    return null;
  }
}

/// 疑似重复导入(同一客户单号 / 同一文件 / 明细基本相同), 只提醒不拦截。
class SalesIntakeDuplicate {
  const SalesIntakeDuplicate({
    this.docType,
    this.id,
    this.billNo,
    this.billDate,
    this.reason,
  });

  factory SalesIntakeDuplicate.fromJson(Map<String, dynamic> json) =>
      SalesIntakeDuplicate(
        docType: _str(json['docType']),
        id: _str(json['id']),
        billNo: _str(json['billNo']),
        billDate: _str(json['billDate']),
        reason: _str(json['reason']),
      );

  final String? docType;
  final String? id;
  final String? billNo;
  final String? billDate;
  final String? reason;
}

/// 一个候选货品(每行最多 8 个, 服务端排好序)。
class SalesIntakeCandidate {
  const SalesIntakeCandidate({
    required this.goodsId,
    this.code,
    this.name,
    this.model,
    this.series,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.nameEn,
    this.reasons = const [],
    this.listPrice,
    this.discount,
    this.rateUsed,
    this.pricingFlag,
    this.pricingNote,
    this.orderBlocked = false,
    this.pickedManually = false,
    this.listPriceUnknown = false,
  });

  factory SalesIntakeCandidate.fromJson(Map<String, dynamic> json) =>
      SalesIntakeCandidate(
        goodsId: _str(json['goodsId']) ?? '',
        code: _str(json['code']),
        name: _str(json['name']),
        model: _str(json['model']),
        series: _str(json['series']),
        spec: _str(json['spec']),
        colorId: _str(json['colorId']),
        colorName: _str(json['colorName']),
        unitId: _str(json['unitId']),
        unitName: _str(json['unitName']),
        nameEn: _str(json['nameEn']),
        reasons: _strings(json['reasons']),
        listPrice: _decimal(json['listPrice']),
        discount: _decimal(json['discount']),
        rateUsed: _decimal(json['rateUsed']),
        pricingFlag: _str(json['pricingFlag'])?.toUpperCase(),
        pricingNote: _str(json['pricingNote']),
        orderBlocked: _bool(json['orderBlocked']),
      );

  final String goodsId;
  final String? code;
  final String? name;
  final String? model;
  final String? series;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? nameEn;

  /// 大白话理由: 型号一致 / 系列一致 / 该客户买过(3次) ...
  final List<String> reasons;

  /// 标价(本位币)。看不到价格的账号服务端已剔除(summary.priceMasked)。
  final String? listPrice;

  /// 按文件单价反推的折扣(4 位小数)。无法可靠计算时为 null。
  final String? discount;
  final String? rateUsed;
  final String? pricingFlag;
  final String? pricingNote;

  /// 服务端给的「订货单不能直接导入」标记(不含价格, 看不到价格的账号也保留;
  /// 服务端尚未下发时为 false, 此时只按定价标记判断)。
  final bool orderBlocked;

  /// 销售在面板里「从货品资料选择」的货品(非服务端候选)。
  final bool pickedManually;

  /// 手工选的货品, 货品选择器没给标价(没有货品价格查看权限时标价被隐藏, 与「没有标价」
  /// 分不清): 不在本地判断标价, 不拦截, 折扣留给销售填写; 真没有标价的货品在明细表
  /// 保存时仍会因单价为空被拦下, 服务端也按货品资料标价核对。
  final bool listPriceUnknown;

  /// 标价为 0/空, 或文件单价高于标价: 订货单不能直接导入, 须先做报价单交财务定价。
  bool get blocksOrder =>
      orderBlocked ||
      pricingFlag == SalesIntakePricingFlag.noListPrice ||
      pricingFlag == SalesIntakePricingFlag.aboveList;

  /// 组合件拆开后的一个部件没有自己的文件单价, 只看标价是否缺失(不看「高于标价」)。
  /// [priceVisible] 为 true 时标价已随结果下发, 标价为空/0 也算缺失。
  bool partBlocksOrder({required bool priceVisible}) {
    // 看不到价格: 部件按「没有文件单价」定价, 服务端的阻断标记只可能来自标价缺失。
    if (!priceVisible) return orderBlocked;
    if (listPriceUnknown) return false;
    if (pricingFlag == SalesIntakePricingFlag.noListPrice) return true;
    final list = double.tryParse(listPrice ?? '');
    return list == null || list <= 0;
  }

  /// 有可直接带入的折扣。
  bool get hasUsableDiscount =>
      discount != null &&
      (pricingFlag == null ||
          pricingFlag == SalesIntakePricingFlag.ok ||
          pricingFlag == SalesIntakePricingFlag.rounded);

  /// 下拉里一行: 名称(编号) · 颜色 · 系列。
  String get displayLabel {
    final head = [name ?? model ?? goodsId, if (code != null) '($code)'].join();
    return [head, ?colorName, ?series].join(' · ');
  }

  SalesIntakeCandidate withPricing({
    String? listPrice,
    String? discount,
    String? pricingFlag,
  }) => SalesIntakeCandidate(
    goodsId: goodsId,
    code: code,
    name: name,
    model: model,
    series: series,
    spec: spec,
    colorId: colorId,
    colorName: colorName,
    unitId: unitId,
    unitName: unitName,
    nameEn: nameEn,
    reasons: reasons,
    listPrice: listPrice,
    discount: discount,
    rateUsed: rateUsed,
    pricingFlag: pricingFlag,
    pricingNote: pricingNote,
    orderBlocked: orderBlocked,
    pickedManually: pickedManually,
    listPriceUnknown: listPriceUnknown,
  );
}

class SalesIntakeWarning {
  const SalesIntakeWarning({required this.code, this.message});

  factory SalesIntakeWarning.fromJson(Map<String, dynamic> json) =>
      SalesIntakeWarning(
        code: _str(json['code'])?.toUpperCase() ?? '',
        message: _str(json['message']),
      );

  final String code;
  final String? message;
}

/// 组合件(A+B+C)里的一个部件, 面板可「拆成 N 行」逐个选货品。
class SalesIntakeBundlePart {
  const SalesIntakeBundlePart({
    required this.partNo,
    this.candidates = const [],
  });

  factory SalesIntakeBundlePart.fromJson(Map<String, dynamic> json) =>
      SalesIntakeBundlePart(
        partNo: _str(json['partNo']) ?? '',
        candidates: [
          for (final c in _maps(json['candidates']))
            if (_str(c['goodsId']) != null) SalesIntakeCandidate.fromJson(c),
        ],
      );

  final String partNo;
  final List<SalesIntakeCandidate> candidates;
}

class SalesIntakeAiSuggestion {
  const SalesIntakeAiSuggestion({required this.goodsId, this.reason});

  final String goodsId;
  final String? reason;
}

/// 文件里的一行明细 + 服务端对应结果。
class SalesIntakeLine {
  const SalesIntakeLine({
    required this.key,
    this.sourceSheet,
    this.sourceRow,
    this.lineNo,
    this.partNo,
    this.description,
    this.descriptionAlt,
    this.series,
    this.color,
    this.colorAlt,
    this.qty,
    this.unit,
    this.suggestedQty,
    this.customerUnitPrice,
    this.customerAmount,
    this.bundle = false,
    this.bundleParts = const [],
    this.assembled = false,
    this.status = SalesIntakeLineStatus.review,
    this.confidence = SalesIntakeConfidence.low,
    this.reasonText,
    this.selectedGoodsId,
    this.aiSuggestion,
    this.setNameEnDefault = false,
    this.nameEnText,
    this.candidates = const [],
    this.warnings = const [],
  });

  factory SalesIntakeLine.fromJson(Map<String, dynamic> json) {
    final suggestion = _map(json['aiSuggestion']);
    final suggestedId = _str(suggestion['goodsId']);
    return SalesIntakeLine(
      key: _str(json['key']) ?? '',
      sourceSheet: _str(json['sourceSheet']),
      sourceRow: _int(json['sourceRow']),
      lineNo: _str(json['lineNo']),
      partNo: _str(json['partNo']),
      description: _str(json['description']),
      descriptionAlt: _str(json['descriptionAlt']),
      series: _str(json['series']),
      color: _str(json['color']),
      colorAlt: _str(json['colorAlt']),
      qty: _decimal(json['qty']),
      unit: _str(json['unit']),
      suggestedQty: _decimal(json['suggestedQty']),
      customerUnitPrice: _decimal(json['customerUnitPrice']),
      customerAmount: _decimal(json['customerAmount']),
      bundle: _bool(json['bundle']),
      bundleParts: [
        for (final part in _maps(json['bundleParts']))
          if (_str(part['partNo']) != null)
            SalesIntakeBundlePart.fromJson(part),
      ],
      assembled: _bool(json['assembled']),
      status: SalesIntakeLineStatus.parse(json['status']),
      confidence: SalesIntakeConfidence.parse(json['confidenceLevel']),
      reasonText: _str(json['reasonText']),
      selectedGoodsId: _str(json['selectedGoodsId']),
      aiSuggestion: suggestedId == null
          ? null
          : SalesIntakeAiSuggestion(
              goodsId: suggestedId,
              reason: _str(suggestion['reason']),
            ),
      setNameEnDefault: _bool(json['setNameEnDefault']),
      nameEnText: _str(json['nameEnText']),
      candidates: [
        for (final c in _maps(json['candidates']))
          if (_str(c['goodsId']) != null) SalesIntakeCandidate.fromJson(c),
      ],
      warnings: [
        for (final w in _maps(json['warnings']))
          if (_str(w['code']) != null) SalesIntakeWarning.fromJson(w),
      ],
    );
  }

  /// 作业内稳定的行键(S<工作表序号>R<行号>), 保存时作为 intakeLineKey 回传。
  final String key;
  final String? sourceSheet;
  final int? sourceRow;
  final String? lineNo;
  final String? partNo;

  /// 拉丁文描述(学英文名只用这一段)。
  final String? description;

  /// 中文描述。
  final String? descriptionAlt;
  final String? series;
  final String? color;
  final String? colorAlt;
  final String? qty;
  final String? unit;

  /// 文件按箱计数且有每箱个数时的换算数量(需核对)。
  final String? suggestedQty;

  /// 文件单价(文件币种)。
  final String? customerUnitPrice;
  final String? customerAmount;
  final bool bundle;
  final List<SalesIntakeBundlePart> bundleParts;
  final bool assembled;
  final SalesIntakeLineStatus status;
  final SalesIntakeConfidence confidence;

  /// 大白话原因(颜色没对上 / 找到 3 个相似货品, 请选一个 / 没找到这个货品)。
  final String? reasonText;
  final String? selectedGoodsId;
  final SalesIntakeAiSuggestion? aiSuggestion;
  final bool setNameEnDefault;
  final String? nameEnText;
  final List<SalesIntakeCandidate> candidates;
  final List<SalesIntakeWarning> warnings;

  /// 服务端预选(规则或 AI 建议)的候选。
  SalesIntakeCandidate? get preselected {
    final id = selectedGoodsId ?? aiSuggestion?.goodsId;
    if (id == null) return null;
    for (final c in candidates) {
      if (c.goodsId == id) return c;
    }
    return null;
  }

  SalesIntakeWarning? warning(String code) {
    for (final w in warnings) {
      if (w.code == code) return w;
    }
    return null;
  }

  /// 文件品名: 优先英文描述, 没有再用中文描述。
  String? get clientGoodsName => description ?? descriptionAlt;

  /// 面板上一行文件原文的简短标识。
  String get fileLabel => [
    ?partNo,
    ?description,
    if (description == null) ?descriptionAlt,
  ].join(' ');
}

class SalesIntakeSummary {
  const SalesIntakeSummary({
    this.lineCount = 0,
    this.matched = 0,
    this.review = 0,
    this.unmatched = 0,
    this.customerTotal,
    this.unpricedCustomerAmount,
    this.priceMasked = false,
  });

  factory SalesIntakeSummary.fromJson(Map<String, dynamic> json) =>
      SalesIntakeSummary(
        lineCount: _int(json['lineCount']) ?? 0,
        matched: _int(json['matched']) ?? 0,
        review: _int(json['review']) ?? 0,
        unmatched: _int(json['unmatched']) ?? 0,
        customerTotal: _decimal(json['customerTotal']),
        unpricedCustomerAmount: _decimal(json['unpricedCustomerAmount']),
        priceMasked: _bool(json['priceMasked']),
      );

  final int lineCount;
  final int matched;
  final int review;
  final int unmatched;
  final String? customerTotal;
  final String? unpricedCustomerAmount;

  /// 当前账号看不到价格: 标价/折扣已剔除, 保存时折扣交服务端按文件单价计算。
  final bool priceMasked;
}

/// 一次识别的完整结果(ai_jobs.result)。
class SalesIntakeResult {
  const SalesIntakeResult({
    this.schemaVersion = kSalesIntakeSchemaVersion,
    this.docType,
    this.file = const SalesIntakeFileInfo(),
    this.header = const SalesIntakeHeader(),
    this.currency = const SalesIntakeCurrency(),
    this.client = const SalesIntakeClientBlock(),
    this.duplicates = const [],
    this.lines = const [],
    this.summary = const SalesIntakeSummary(),
    this.notices = const [],
  });

  /// 结果不是对象时抛 [FormatException](页面提示「识别结果无法读取」)。
  factory SalesIntakeResult.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('sales intake result is not an object');
    }
    final json = Map<String, dynamic>.from(raw);
    final seenKeys = <String>{};
    return SalesIntakeResult(
      schemaVersion: _int(json['schemaVersion']) ?? kSalesIntakeSchemaVersion,
      docType: _str(json['docType']),
      file: SalesIntakeFileInfo.fromJson(_map(json['file'])),
      header: SalesIntakeHeader.fromJson(_map(json['header'])),
      currency: SalesIntakeCurrency.fromJson(_map(json['currency'])),
      client: SalesIntakeClientBlock.fromJson(_map(json['client'])),
      duplicates: [
        for (final d in _maps(json['duplicates']))
          SalesIntakeDuplicate.fromJson(d),
      ],
      lines: [
        for (final line in _maps(json['lines']))
          // 行键缺失或重复的行无法回传学习, 视为损坏数据丢弃。
          if (_str(line['key']) case final key? when seenKeys.add(key))
            SalesIntakeLine.fromJson(line),
      ],
      summary: SalesIntakeSummary.fromJson(_map(json['summary'])),
      notices: _strings(json['notices']),
    );
  }

  final int schemaVersion;
  final String? docType;
  final SalesIntakeFileInfo file;
  final SalesIntakeHeader header;
  final SalesIntakeCurrency currency;
  final SalesIntakeClientBlock client;
  final List<SalesIntakeDuplicate> duplicates;
  final List<SalesIntakeLine> lines;
  final SalesIntakeSummary summary;
  final List<String> notices;

  bool get priceMasked => summary.priceMasked;
}

/// 编辑页上「本单来自哪次识别」的状态: 保存时作为 `aiIntake` 提交, 新建页随草稿保存。
class SalesIntakeSession {
  const SalesIntakeSession({
    required this.jobId,
    this.clientId,
    this.clientFields = const {},
    this.clientFileCurrency,
    this.financeRate,
    this.rateMissing = false,
    this.fileName,
    this.priceMasked = false,
    this.importedRows = 0,
  });

  factory SalesIntakeSession.fromJson(Map<String, dynamic> json) =>
      SalesIntakeSession(
        jobId: _str(json['jobId']) ?? '',
        clientId: _str(json['clientId']),
        clientFields: {
          for (final entry in _map(json['clientFields']).entries)
            if (kSalesIntakeClientFieldKeys.contains(entry.key) &&
                _str(entry.value) != null)
              entry.key: _str(entry.value)!,
        },
        clientFileCurrency: _str(json['clientFileCurrency']),
        financeRate: _decimal(json['financeRate']),
        rateMissing: _bool(json['rateMissing']),
        fileName: _str(json['fileName']),
        priceMasked: _bool(json['priceMasked']),
        importedRows: _int(json['importedRows']) ?? 0,
      );

  final String jobId;

  /// 导入时表头的客户; [clientFields] 只对这个客户有效。
  final String? clientId;

  /// 用户勾选「保存时补进客户资料」的字段 → 文件里的值(只补 [clientId] 这个客户)。
  final Map<String, String> clientFields;
  final String? clientFileCurrency;

  /// 识别时的财务参考汇率(明细里换货品后重新反推折扣用)。
  final String? financeRate;
  final bool rateMissing;
  final String? fileName;
  final bool priceMasked;
  final int importedRows;

  bool get isValid => jobId.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'clientId': clientId,
    'clientFields': clientFields,
    'clientFileCurrency': clientFileCurrency,
    'financeRate': financeRate,
    'rateMissing': rateMissing,
    'fileName': fileName,
    'priceMasked': priceMasked,
    'importedRows': importedRows,
  };

  /// 保存请求体里的 `aiIntake`(SPEC §6.1)。[currentClientId] 是保存时表头的客户:
  /// 导入后换了客户, 文件里的客户信息不能补到另一个客户身上, 只提交空字段。
  Map<String, dynamic> toSaveJson({required String? currentClientId}) => {
    'jobId': jobId,
    'clientFields': clientId != null && clientId == currentClientId
        ? clientFields
        : const <String, String>{},
  };
}
