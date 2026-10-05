// 销售客户文件识别(ADR-134): 识别结果 + 用户在核对面板里的选择 → 编辑页补丁。
//
// 纯函数, 不依赖 BuildContext / 网络 / Riverpod, 单元测试直接覆盖。编辑页只负责把
// [SalesIntakePatch] 套进表头与明细表(约 40 行)。
//
// 价格铁律(SPEC §5.7): 本文件永远不写单价——单价只来自货品资料标价(只读预览,
// 服务端锁定); 文件单价只用来反推折扣。看不到价格的账号折扣一律留空并提交 null,
// 由服务端按文件单价计算。
library;

import '../../../core/l10n/gen/app_localizations.dart';
import '../models/sales_doc.dart';
import 'sales_intake_models.dart';

/// 一行(或拆开后的一个部件)在面板里的选择。
class SalesIntakePartDecision {
  SalesIntakePartDecision({
    required this.partNo,
    required this.candidates,
    this.goods,
    this.include = true,
    this.userConfirmed = false,
  });

  final String partNo;
  final List<SalesIntakeCandidate> candidates;
  SalesIntakeCandidate? goods;
  bool include;
  bool userConfirmed;
}

class SalesIntakeLineDecision {
  SalesIntakeLineDecision({
    this.goods,
    this.include = true,
    this.userConfirmed = false,
    this.setNameEn = false,
    this.split = false,
    List<SalesIntakePartDecision>? parts,
  }) : parts = parts ?? [];

  /// 选中的货品(服务端候选之一, 或「从货品资料选择」的货品)。
  SalesIntakeCandidate? goods;

  /// 是否导入明细表。
  bool include;

  /// 用户在面板里明确选过/确认过(学习时计为「人工确认」)。
  bool userConfirmed;

  /// 保存后把文件英文品名写进这个货品的英文名称(§5.8)。
  bool setNameEn;

  /// 组合件已「拆成 N 行」。
  bool split;
  final List<SalesIntakePartDecision> parts;
}

/// 核对面板的全部选择。
class SalesIntakeDecisions {
  SalesIntakeDecisions({
    required this.lines,
    this.clientId,
    this.clientName,
    this.enrichmentEnabled = false,
    Map<String, bool>? enrichmentFields,
    Set<String>? includedExtraColumns,
  }) : enrichmentFields = enrichmentFields ?? {},
       includedExtraColumns = includedExtraColumns ?? {};

  /// 按识别结果给出默认选择:
  /// - 自动对上的行导入; 需要核对的行有预选货品才导入(导入后明细表黄色提醒);
  /// - 没找到货品的行不导入(文字写进备注);
  /// - 订货单上标价为 0 或文件单价高于标价的行不能导入(要先做报价单交财务定价);
  ///   组合件拆开后标价为 0 的部件同样不能导入。
  factory SalesIntakeDecisions.initial(
    SalesIntakeResult result, {
    required SalesDocType docType,
    String? presetClientId,
    String? presetClientName,
  }) {
    final lines = <String, SalesIntakeLineDecision>{};
    for (final line in result.lines) {
      final goods = line.preselected;
      final decision = SalesIntakeLineDecision(
        goods: goods,
        setNameEn: line.setNameEnDefault && line.nameEnText != null,
        parts: [
          for (final part in line.bundleParts)
            SalesIntakePartDecision(
              partNo: part.partNo,
              candidates: part.candidates,
              goods: part.candidates.isEmpty ? null : part.candidates.first,
              include:
                  part.candidates.isNotEmpty &&
                  !salesIntakePartBlocked(
                    docType: docType,
                    goods: part.candidates.first,
                    priceMasked: result.priceMasked,
                  ),
            ),
        ],
      );
      decision.include =
          goods != null &&
          line.status != SalesIntakeLineStatus.unmatched &&
          !salesIntakeGoodsBlocked(
            docType: docType,
            goods: goods,
            priceMasked: result.priceMasked,
          );
      lines[line.key] = decision;
    }
    final client = result.client;
    final clientId = client.selectedClientId ?? presetClientId;
    final candidate = client.candidate(clientId);
    return SalesIntakeDecisions(
      lines: lines,
      clientId: clientId,
      clientName: candidate?.displayName ?? presetClientName,
      enrichmentEnabled: client.enrichment.any((f) => f.defaultChecked),
      enrichmentFields: {
        for (final field in client.enrichment)
          field.field: field.defaultChecked,
      },
      includedExtraColumns: result.extraColumns
          .map((column) => column.key)
          .toSet(),
    );
  }

  String? clientId;
  String? clientName;

  /// 「保存时补进客户资料」总开关。
  bool enrichmentEnabled;
  final Map<String, bool> enrichmentFields;
  final Map<String, SalesIntakeLineDecision> lines;
  final Set<String> includedExtraColumns;

  SalesIntakeLineDecision decisionFor(SalesIntakeLine line) =>
      lines.putIfAbsent(line.key, SalesIntakeLineDecision.new);
}

/// Only unambiguous, high-confidence rows may be put into an unsaved form
/// without a review dialog. This never means the document is approved.
bool salesIntakeCanAutoApply(SalesIntakeResult result, SalesDocType docType) =>
    result.client.status.resolved &&
    result.client.selectedClientId != null &&
    result.client.mismatchWarning == null &&
    result.duplicates.isEmpty &&
    result.notices.isEmpty &&
    result.extraColumns.isEmpty &&
    result.file.otherSheets.isEmpty &&
    result.lines.isNotEmpty &&
    result.lines.every(
      (line) =>
          line.status == SalesIntakeLineStatus.matched &&
          line.confidence == SalesIntakeConfidence.high &&
          !line.bundle &&
          line.suggestedQty == null &&
          line.warnings.isEmpty &&
          line.preselected != null &&
          (_Dec.parse(line.qty)?.isPositive ?? false) &&
          !salesIntakeGoodsBlocked(
            docType: docType,
            goods: line.preselected,
            priceMasked: result.priceMasked,
          ),
    );

/// Guided form filling cannot silently create reusable columns or master-data
/// learning instructions. The original source file retains omitted columns.
void restrictGuidedIntakeDecisions(SalesIntakeDecisions decisions) {
  decisions.enrichmentEnabled = false;
  decisions.enrichmentFields.clear();
  decisions.includedExtraColumns.clear();
  for (final decision in decisions.lines.values) {
    decision.setNameEn = false;
  }
}

/// 订货单不能直接导入标价为 0/空、或文件单价高于标价的货品(§5.7)。
/// 看不到价格的账号拿不到定价标记, 只看服务端保留的「不能导入」标记 orderBlocked
/// (服务端还没下发这个标记时不拦, 保存时由服务端按货品资料标价处理)。
bool salesIntakeGoodsBlocked({
  required SalesDocType docType,
  required SalesIntakeCandidate? goods,
  required bool priceMasked,
}) =>
    docType == SalesDocType.order &&
    goods != null &&
    (priceMasked ? goods.orderBlocked : goods.blocksOrder);

/// 组合件拆开后的一个部件: 订货单上标价为空/0 的不能导入(部件没有自己的文件单价,
/// 不按「高于标价」判断)。
bool salesIntakePartBlocked({
  required SalesDocType docType,
  required SalesIntakeCandidate? goods,
  required bool priceMasked,
}) =>
    docType == SalesDocType.order &&
    goods != null &&
    goods.partBlocksOrder(priceVisible: !priceMasked);

/// 部件当前是否会导入。
bool salesIntakePartImported(
  SalesIntakePartDecision part, {
  required SalesDocType docType,
  required bool priceMasked,
}) =>
    part.include &&
    part.goods != null &&
    !salesIntakePartBlocked(
      docType: docType,
      goods: part.goods,
      priceMasked: priceMasked,
    );

/// 行(含拆开的部件)当前会导入几行明细。
int salesIntakeRowCount(
  SalesIntakeLine line,
  SalesIntakeLineDecision decision, {
  required SalesDocType docType,
  required bool priceMasked,
}) {
  if (decision.split) {
    return decision.parts
        .where(
          (p) => salesIntakePartImported(
            p,
            docType: docType,
            priceMasked: priceMasked,
          ),
        )
        .length;
  }
  final importable =
      decision.include &&
      decision.goods != null &&
      !salesIntakeGoodsBlocked(
        docType: docType,
        goods: decision.goods,
        priceMasked: priceMasked,
      );
  return importable ? 1 : 0;
}

/// 「设为货品英文名」只对会整行导入的行给出(§5.8): 没勾上的、订货单不能导入的、没找到货品的、
/// 拆开的组合件都不给, 保存时也不会带 setNameEn=true。
bool salesIntakeNameEnOffered(
  SalesIntakeLine line,
  SalesIntakeLineDecision decision, {
  required SalesDocType docType,
  required bool priceMasked,
}) =>
    line.nameEnText != null &&
    !decision.split &&
    salesIntakeRowCount(
          line,
          decision,
          docType: docType,
          priceMasked: priceMasked,
        ) ==
        1;

/// 这一行是否还需要用户看一眼(需要核对的、没找到的、订货单不能导入的)。
bool salesIntakeLineNeedsReview(
  SalesIntakeLine line,
  SalesIntakeLineDecision decision, {
  required SalesDocType docType,
  required bool priceMasked,
}) {
  if (line.status != SalesIntakeLineStatus.matched) return true;
  if (line.bundle || line.suggestedQty != null) return true;
  const attention = {
    SalesIntakeWarningCode.unitNotPcs,
    SalesIntakeWarningCode.amountMismatch,
    SalesIntakeWarningCode.duplicateGoods,
  };
  if (line.warnings.any((w) => attention.contains(w.code))) return true;
  final goods = decision.goods;
  // 折扣没能算出(导入后要填): 也放进「需要核对」。
  if (!priceMasked && goods != null && !goods.hasUsableDiscount) return true;
  return salesIntakeGoodsBlocked(
    docType: docType,
    goods: goods,
    priceMasked: priceMasked,
  );
}

/// 这一行里订货单不能导入的货品个数: 整行 1 个; 拆开的组合件按部件计。
int _blockedGoodsCount(
  SalesIntakeLineDecision decision, {
  required SalesDocType docType,
  required bool priceMasked,
}) {
  if (decision.split) {
    return decision.parts
        .where(
          (p) => salesIntakePartBlocked(
            docType: docType,
            goods: p.goods,
            priceMasked: priceMasked,
          ),
        )
        .length;
  }
  return salesIntakeGoodsBlocked(
        docType: docType,
        goods: decision.goods,
        priceMasked: priceMasked,
      )
      ? 1
      : 0;
}

/// 订货单上因为没有标价/文件单价高于标价而不能导入的行(含有这种部件的组合件)。
List<SalesIntakeLine> salesIntakeBlockedLines(
  SalesIntakeResult result,
  SalesIntakeDecisions decisions, {
  required SalesDocType docType,
}) => [
  for (final line in result.lines)
    if (_blockedGoodsCount(
          decisions.decisionFor(line),
          docType: docType,
          priceMasked: result.priceMasked,
        ) >
        0)
      line,
];

/// 订货单上不能导入的货品个数(拆开的组合件按部件计), 用于「这 N 个货品还没有标价」。
int salesIntakeBlockedGoodsCount(
  SalesIntakeResult result,
  SalesIntakeDecisions decisions, {
  required SalesDocType docType,
}) {
  var total = 0;
  for (final line in result.lines) {
    total += _blockedGoodsCount(
      decisions.decisionFor(line),
      docType: docType,
      priceMasked: result.priceMasked,
    );
  }
  return total;
}

// ---------------------------------------------------------------------------
// 折扣预览: 与服务端 MoneyPolicy.discountFromUnitPrice 同一规则(§5.7), 只用于
// 「从货品资料选择」的货品(服务端候选已算好)。十进制整数运算, 不经浮点。
// ---------------------------------------------------------------------------

class SalesIntakeDiscountPreview {
  const SalesIntakeDiscountPreview({this.discount, this.flag});

  /// 4 位小数折扣文本; 无法可靠计算时为 null。
  final String? discount;

  /// 定价标记; 没有文件单价(有标价)时为 null, 与服务端一致。
  final String? flag;
}

class _Dec {
  const _Dec(this.units, this.scale);

  final BigInt units;
  final int scale;

  static _Dec? parse(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;
    final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(text);
    if (match == null) return null;
    final fraction = match.group(3) ?? '';
    final digits = '${match.group(2)}$fraction';
    final units = BigInt.parse(digits);
    return _Dec(match.group(1) == '-' ? -units : units, fraction.length);
  }

  bool get isPositive => units > BigInt.zero;
}

BigInt _pow10(int n) => BigInt.from(10).pow(n);

/// 比例 = 文件单价 × 汇率 ÷ 标价, 以分子/分母表示(都为正)。
({BigInt num, BigInt den})? _ratio(_Dec price, _Dec rate, _Dec list) {
  if (!list.isPositive || !price.isPositive || !rate.isPositive) return null;
  final num = price.units * rate.units * _pow10(list.scale);
  final den = list.units * _pow10(price.scale + rate.scale);
  return (num: num, den: den);
}

/// 比例四舍五入到 4 位后的值, 以万分之一为单位(与服务端 MoneyPolicy 同一取位)。
BigInt _rounded4Units(({BigInt num, BigInt den}) r) =>
    (r.num * BigInt.from(10000) * BigInt.two + r.den) ~/ (r.den * BigInt.two);

/// 取 4 位后的折扣落在 (0.3, 1]: 与服务端识别定价、看不到价格的人保存时反推折扣是同一个判断
/// (判断的是取位后的折扣, 不是原始比例)。
bool _inRange(({BigInt num, BigInt den}) r) {
  final q = _rounded4Units(r);
  return q > BigInt.from(3000) && q <= BigInt.from(10000);
}

/// 取 4 位后大于 1(高于标价)。
bool _aboveList(({BigInt num, BigInt den}) r) =>
    _rounded4Units(r) > BigInt.from(10000);

String _roundHalfUp4(({BigInt num, BigInt den}) r) {
  final q = _rounded4Units(r);
  final text = q.toString().padLeft(5, '0');
  final whole = text.substring(0, text.length - 4);
  final fraction = text
      .substring(text.length - 4)
      .replaceAll(RegExp(r'0+$'), '');
  return fraction.isEmpty ? whole : '$whole.$fraction';
}

bool _roundedExactly(({BigInt num, BigInt den}) r) =>
    (r.num * BigInt.from(10000)) % r.den == BigInt.zero;

/// 按文件单价反推折扣(§5.7):
/// - 标价为空或 0 → NO_LIST_PRICE;
/// - 没有文件单价 → 不给折扣也不给标记(与服务端 IntakePricing 一致);
/// - 同时按「汇率 1」与「财务参考汇率」算比例, 恰好一个落在 (0.3, 1] 才采用;
/// - 两个都在区间 → AMBIGUOUS_CURRENCY; 都不在 → ABOVE_LIST(大于 1) 或 OUT_OF_RANGE;
/// - 外币文件没有参考汇率且按 1 算不在区间 → RATE_MISSING。
SalesIntakeDiscountPreview salesIntakeDiscountPreview({
  required String? customerUnitPrice,
  required String? listPrice,
  String? fileCurrency,
  String? financeRate,
  bool rateMissing = false,
}) {
  final list = _Dec.parse(listPrice);
  if (list == null || !list.isPositive) {
    return const SalesIntakeDiscountPreview(
      flag: SalesIntakePricingFlag.noListPrice,
    );
  }
  final price = _Dec.parse(customerUnitPrice);
  if (price == null || !price.isPositive) {
    return const SalesIntakeDiscountPreview();
  }
  final one = _Dec(BigInt.one, 0);
  final rate = _Dec.parse(financeRate);
  final foreign = fileCurrency != null && fileCurrency.isNotEmpty;
  // 本位币文件服务端不给汇率(或给 1): 只按 1 算; 外币文件用财务参考汇率。
  final useRate =
      foreign &&
      rate != null &&
      rate.isPositive &&
      !(rate.units == _pow10(rate.scale));
  final q1 = _ratio(price, one, list)!;
  final qr = useRate ? _ratio(price, rate, list) : null;
  final q1Ok = _inRange(q1);
  final qrOk = qr != null && _inRange(qr);
  if (q1Ok && qrOk) {
    return const SalesIntakeDiscountPreview(
      flag: SalesIntakePricingFlag.ambiguousCurrency,
    );
  }
  final chosen = q1Ok ? q1 : (qrOk ? qr : null);
  if (chosen != null) {
    return SalesIntakeDiscountPreview(
      discount: _roundHalfUp4(chosen),
      flag: _roundedExactly(chosen)
          ? SalesIntakePricingFlag.ok
          : SalesIntakePricingFlag.rounded,
    );
  }
  if (foreign && !useRate && rateMissing) {
    return const SalesIntakeDiscountPreview(
      flag: SalesIntakePricingFlag.rateMissing,
    );
  }
  final above = _aboveList(q1) && (qr == null || _aboveList(qr));
  return SalesIntakeDiscountPreview(
    flag: above
        ? SalesIntakePricingFlag.aboveList
        : SalesIntakePricingFlag.outOfRange,
  );
}

/// 「从货品资料选择」的货品转成候选: 定价按同一规则在本地预览。
/// - [listPrice] 为 null(货品选择器没给标价, 可能只是当前账号看不到货品价格): 不在本地
///   判断标价/折扣, 也不拦截, 折扣留给销售填写; 标价为 0 才按「没有标价」处理;
/// - [bundlePart]: 组合件拆开后的部件没有自己的文件单价, 只看标价是否缺失。
SalesIntakeCandidate salesIntakeManualCandidate({
  required String goodsId,
  String? code,
  String? name,
  String? model,
  String? series,
  String? spec,
  String? colorId,
  String? colorName,
  String? unitId,
  String? unitName,
  String? listPrice,
  bool bundlePart = false,
  required SalesIntakeLine line,
  required SalesIntakeCurrency currency,
  required bool priceMasked,
  required String reason,
}) {
  final base = SalesIntakeCandidate(
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
    reasons: [reason],
    pickedManually: true,
    listPriceUnknown: listPrice == null && !priceMasked,
  );
  if (priceMasked || listPrice == null) return base;
  final preview = salesIntakeDiscountPreview(
    customerUnitPrice: bundlePart ? null : line.customerUnitPrice,
    listPrice: listPrice,
    fileCurrency: currency.fileCurrency,
    financeRate: currency.financeRate,
    rateMissing: currency.rateMissing,
  );
  return base.withPricing(
    listPrice: listPrice,
    discount: preview.discount,
    pricingFlag: preview.flag,
  );
}

// ---------------------------------------------------------------------------
// 补丁
// ---------------------------------------------------------------------------

/// 明细表的一行。
class SalesIntakePatchRow {
  const SalesIntakePatchRow({
    required this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.goodsNameEn,
    this.colorId,
    this.unitId,
    required this.qty,
    this.listPrice,
    this.discount,
    this.clientModel,
    this.clientGoodsName,
    this.clientPrice,
    this.intakeLineKey,
    this.userConfirmed = false,
    this.setNameEn = false,
    this.reviewReason,
    this.goodsMatchReason,
    this.remark,
    this.extraValues = const {},
  });

  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? goodsNameEn;
  final String? colorId;
  final String? unitId;
  final String qty;

  /// 标价预览(只读, 服务端锁定); 看不到价格或没有标价时为 null。
  final String? listPrice;

  /// 折扣文本: 有值=带入; '' = 待填/待财务核价(黄色提醒); null = 看不到价格(提交 null)。
  final String? discount;
  final String? clientModel;
  final String? clientGoodsName;

  /// 文件单价(文件币种)。
  final String? clientPrice;
  final String? intakeLineKey;
  final bool userConfirmed;
  final bool setNameEn;

  /// 非 null → 明细表黄色提醒核对(只有需要核对的行才有)。
  final String? reviewReason;

  /// [reviewReason] 开头那段「货品没对准」提醒(确认货品对应后只清它; 单位/金额/重复/定价提醒保留)。
  final String? goodsMatchReason;

  /// 行备注(组合件拆开后, 第一行记下整套的文件单价供参考)。
  final String? remark;
  final Map<String, String> extraValues;
}

class SalesIntakePatch {
  const SalesIntakePatch({
    required this.jobId,
    required this.rows,
    this.clientId,
    this.clientName,
    this.contractNo,
    this.remark,
    this.currencyId,
    this.clientFileCurrency,
    this.financeRate,
    this.rateMissing = false,
    this.clientFields = const {},
    this.priceMasked = false,
    this.fileName,
    this.reviewRowCount = 0,
    this.skippedUnmatched = 0,
    this.blockedUnpriced = 0,
    this.extraColumns = const [],
  });

  final String jobId;
  final List<SalesIntakePatchRow> rows;
  final String? clientId;

  /// 客户显示名(刚「用文件信息新建」的客户还不在客户字典里, 表头先用它显示)。
  final String? clientName;

  /// 客户单号 → 合同号。
  final String? contractNo;

  /// 追加到备注(贸易条款/付款方式 + 没导入的行)。
  final String? remark;

  /// 本位币(标价所用币种)。
  final String? currencyId;
  final String? clientFileCurrency;
  final String? financeRate;
  final bool rateMissing;

  /// 勾选补进客户资料的字段。
  final Map<String, String> clientFields;
  final bool priceMasked;
  final String? fileName;
  final int reviewRowCount;
  final int skippedUnmatched;
  final int blockedUnpriced;
  final List<SalesIntakeExtraColumn> extraColumns;

  SalesIntakeSession toSession({
    SalesIntakeSession? previous,
    bool preservePreviousPricing = false,
    String? previousFileCurrency,
  }) => SalesIntakeSession(
    jobId: jobId,
    clientId: clientId,
    clientFields: {
      if (previous?.clientId == clientId) ...?previous?.clientFields,
      ...clientFields,
    },
    clientFileCurrency: preservePreviousPricing
        ? previous?.clientFileCurrency ?? previousFileCurrency
        : clientFileCurrency,
    financeRate: preservePreviousPricing ? previous?.financeRate : financeRate,
    // Saved drafts retain file prices but not the transient recognition rate.
    // Appending a file without prices cannot supply a rate for those old prices.
    rateMissing: preservePreviousPricing
        ? previous?.rateMissing ?? (previousFileCurrency != null)
        : rateMissing,
    fileName: fileName,
    priceMasked: priceMasked,
    importedRows: rows.length,
    additionalJobIds: {
      if (previous != null && previous.clientId == clientId) ...[
        previous.jobId,
        ...previous.additionalJobIds,
      ],
    }.where((id) => id != jobId).toList(growable: false),
  );
}

String _lineRemarkLabel(SalesIntakeLine line, AppLocalizations l10n) {
  final label = line.fileLabel.isEmpty
      ? (line.lineNo ?? line.key)
      : line.fileLabel;
  final qty = line.qty;
  return qty == null ? label : l10n.salesIntakeRemarkLineItem(label, qty);
}

/// 「货品没对准」提醒(核对面板里「确认」就清掉的那一项)。
String? _goodsMatchReasonFor(
  SalesIntakeLine line,
  SalesIntakeLineDecision decision,
  AppLocalizations l10n,
) => line.status != SalesIntakeLineStatus.matched && !decision.userConfirmed
    ? line.reasonText ?? l10n.salesIntakeMarkerDefault
    : null;

String? _reviewReasonFor(
  SalesIntakeLine line,
  SalesIntakeLineDecision decision,
  AppLocalizations l10n,
) {
  final reasons = <String>[?_goodsMatchReasonFor(line, decision, l10n)];
  if (line.suggestedQty != null ||
      line.warning(SalesIntakeWarningCode.unitNotPcs) != null) {
    reasons.add(
      line.warning(SalesIntakeWarningCode.unitNotPcs)?.message ??
          l10n.salesIntakeMarkerUnit,
    );
  }
  // The other "please check" warnings the review panel shows for this line
  // (amount mismatch, duplicate goods) stay on the imported row too, so the
  // yellow mark and the AI page snapshot (ADR-150) carry the same reason.
  for (final code in const [
    SalesIntakeWarningCode.amountMismatch,
    SalesIntakeWarningCode.duplicateGoods,
  ]) {
    final message = line.warning(code)?.message?.trim();
    if (message != null && message.isNotEmpty && !reasons.contains(message)) {
      reasons.add(message);
    }
  }
  return reasons.isEmpty ? null : reasons.join(' / ');
}

/// 组合件拆开后部件在备注里的标识: 型号 × 数量。
String _partRemarkLabel(String partNo, String qty, AppLocalizations l10n) =>
    qty.isEmpty ? partNo : l10n.salesIntakeRemarkLineItem(partNo, qty);

/// 识别结果 + 选择 → 补丁。[docType] 是**当前页面**的单据类型(从订货单转来的
/// 识别结果套到报价单时以报价单规则处理)。
///
/// 不导入的文件原文一律写进备注, 不悄悄丢掉: 没找到货品的行(含用户没勾的「没找到」行)、
/// 组合件里没选到货品的部件 → 「没找到对应货品」; 订货单上没有标价(或文件单价高于标价)
/// 的行和部件 → 「还没有标价」。用户自己取消勾选的已对应行不写。
SalesIntakePatch buildSalesIntakePatch({
  required SalesIntakeResult result,
  required SalesIntakeDecisions decisions,
  required SalesDocType docType,
  required String jobId,
  required AppLocalizations l10n,
}) {
  final masked = result.priceMasked;
  final rows = <SalesIntakePatchRow>[];
  final unmatched = <String>[];
  final unpriced = <String>[];
  var reviewRows = 0;

  String? pricingReason(SalesIntakeCandidate goods) {
    if (masked || goods.hasUsableDiscount) return null;
    if (docType == SalesDocType.quote) {
      return goods.blocksOrder
          ? l10n.salesIntakeMarkerQuotePricing
          : l10n.salesIntakeMarkerQuoteDiscount;
    }
    return l10n.salesIntakeMarkerOrderDiscount;
  }

  void addRow({
    required SalesIntakeCandidate goods,
    required String qty,
    required String? discount,
    required String? clientModel,
    required String? clientGoodsName,
    required String? clientPrice,
    required String? intakeLineKey,
    required bool userConfirmed,
    required bool setNameEn,
    required List<String?> reasons,
    String? goodsMatchReason,
    String? remark,
    Map<String, String> extraValues = const {},
  }) {
    // The goods-match reason, when present, comes first (see SalesGridRow.confirmGoodsMatch).
    final shown = reasons.whereType<String>().toList();
    final reason = shown.isEmpty ? null : shown.join(' / ');
    if (reason != null) reviewRows++;
    rows.add(
      SalesIntakePatchRow(
        goodsId: goods.goodsId,
        goodsCode: goods.code,
        goodsName: goods.name ?? goods.model,
        goodsNameEn: goods.nameEn,
        colorId: goods.colorId,
        unitId: goods.unitId,
        qty: qty,
        listPrice: masked ? null : goods.listPrice,
        discount: discount,
        clientModel: clientModel,
        clientGoodsName: clientGoodsName,
        clientPrice: clientPrice,
        intakeLineKey: intakeLineKey,
        userConfirmed: userConfirmed,
        setNameEn: setNameEn,
        reviewReason: reason,
        goodsMatchReason: reason != null && goodsMatchReason != null
            ? goodsMatchReason
            : null,
        remark: remark,
        extraValues: extraValues,
      ),
    );
  }

  final fileCurrency = result.currency.fileCurrency;
  for (final line in result.lines) {
    final decision = decisions.decisionFor(line);
    final qty = line.suggestedQty ?? line.qty ?? '';
    if (decision.split && decision.parts.isNotEmpty) {
      // 拆开的部件没有各自的文件单价: 不挂文件单价(否则折扣会按整套单价对单个部件算),
      // 整套的文件单价写进第一行备注供参考; 折扣留给报价的财务核价 / 订货单销售核对。
      final bundlePrice = line.customerUnitPrice;
      String? bundleRemark = bundlePrice == null
          ? null
          : l10n.salesIntakeRemarkBundlePrice(
              line.partNo ?? line.fileLabel,
              fileCurrency == null ? bundlePrice : '$bundlePrice $fileCurrency',
            );
      var firstImportedPart = true;
      for (final part in decision.parts) {
        final goods = part.goods;
        final label = _partRemarkLabel(part.partNo, qty, l10n);
        if (goods == null) {
          unmatched.add(label);
          continue;
        }
        if (salesIntakePartBlocked(
          docType: docType,
          goods: goods,
          priceMasked: masked,
        )) {
          unpriced.add(label);
          continue;
        }
        if (!part.include) continue;
        addRow(
          goods: goods,
          qty: qty,
          discount: masked ? null : '',
          clientModel: part.partNo,
          clientGoodsName: null,
          clientPrice: null,
          // Keep file provenance for template learning. Part text is different
          // from the bundle source, so it never becomes a global alias/name.
          intakeLineKey: line.key,
          userConfirmed: part.userConfirmed,
          setNameEn: false,
          reasons: [l10n.salesIntakeMarkerBundlePart],
          remark: bundleRemark,
          // A whole-line reference belongs to the first imported component only.
          extraValues: firstImportedPart
              ? {
                  for (final entry in line.extraValues.entries)
                    if (decisions.includedExtraColumns.contains(entry.key))
                      entry.key: entry.value,
                }
              : const {},
        );
        bundleRemark = null;
        firstImportedPart = false;
      }
      continue;
    }
    final goods = decision.goods;
    if (goods == null) {
      // 没找到货品, 或需要核对但一个候选都没选: 文件原文写进备注, 不丢。
      unmatched.add(_lineRemarkLabel(line, l10n));
      continue;
    }
    if (salesIntakeGoodsBlocked(
      docType: docType,
      goods: goods,
      priceMasked: masked,
    )) {
      unpriced.add(_lineRemarkLabel(line, l10n));
      continue;
    }
    if (!decision.include) {
      // 「没找到」的行即使服务端给了建议货品, 默认也不导入: 原文照样写进备注。
      if (line.status == SalesIntakeLineStatus.unmatched) {
        unmatched.add(_lineRemarkLabel(line, l10n));
      }
      continue;
    }
    final discount = masked
        ? null
        : (goods.hasUsableDiscount ? goods.discount! : '');
    addRow(
      goods: goods,
      qty: qty,
      discount: discount,
      clientModel: line.partNo,
      clientGoodsName: line.clientGoodsName,
      clientPrice: line.customerUnitPrice,
      intakeLineKey: line.key,
      userConfirmed: decision.userConfirmed,
      setNameEn:
          decision.setNameEn &&
          salesIntakeNameEnOffered(
            line,
            decision,
            docType: docType,
            priceMasked: masked,
          ),
      reasons: [_reviewReasonFor(line, decision, l10n), pricingReason(goods)],
      goodsMatchReason: _goodsMatchReasonFor(line, decision, l10n),
      extraValues: {
        for (final entry in line.extraValues.entries)
          if (decisions.includedExtraColumns.contains(entry.key))
            entry.key: entry.value,
      },
    );
  }

  final remarkParts = <String>[
    ?result.header.remarkSuggestion,
    if (unmatched.isNotEmpty)
      l10n.salesIntakeRemarkUnmatched(unmatched.length, unmatched.join('; ')),
    if (unpriced.isNotEmpty)
      l10n.salesIntakeRemarkUnpriced(unpriced.length, unpriced.join('; ')),
  ];

  final clientFields = <String, String>{};
  final client = result.client;
  // 补进客户资料只对识别时对上的那个客户有效; 用户换了客户就不补。
  if (decisions.enrichmentEnabled &&
      decisions.clientId != null &&
      decisions.clientId == client.selectedClientId) {
    for (final field in client.enrichment) {
      if (decisions.enrichmentFields[field.field] == true &&
          kSalesIntakeClientFieldKeys.contains(field.field)) {
        clientFields[field.field] = field.proposed;
      }
    }
  }

  return SalesIntakePatch(
    jobId: jobId,
    rows: rows,
    clientId: decisions.clientId,
    clientName: decisions.clientName,
    contractNo: result.header.docNo,
    remark: remarkParts.isEmpty ? null : remarkParts.join('\n'),
    currencyId: result.currency.baseCurrencyId,
    clientFileCurrency: result.currency.fileCurrency,
    financeRate: result.currency.financeRate,
    rateMissing: result.currency.rateMissing,
    clientFields: clientFields,
    priceMasked: masked,
    fileName: result.file.name,
    reviewRowCount: reviewRows,
    skippedUnmatched: unmatched.length,
    blockedUnpriced: unpriced.length,
    extraColumns: [
      for (final column in result.extraColumns)
        if (decisions.includedExtraColumns.contains(column.key) &&
            rows.any((row) => row.extraValues.containsKey(column.key)))
          column,
    ],
  );
}
