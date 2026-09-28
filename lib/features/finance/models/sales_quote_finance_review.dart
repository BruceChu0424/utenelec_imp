// 销售报价财务核价模型(ADR-134 / SPEC §6.2)。
//
// 报价由销售提交(status 2)后进入财务核价队列; 财务认领后逐行定「成交单价 / 折扣」,
// 没有标价(空或 0)或成交价高于标价的货品由财务直接定价(priceSource = FINANCE,
// 0 = 赠品/0价), 然后确认(status 1, 销售才能转订货单)或退回销售(status 0 + 退回原因)。
//
// JSON 契约与服务端逐字一致(ai-quote 包的 record, 冻结于 2026-09-27):
//   · 队列行 QuoteFinanceListItem、核价详情 QuoteFinanceReviewDto(+ Line / QuoteRevisionDto);
//   · 保存 QuoteFinanceEditRequest: 表头 validUntil / settlementMethodId / financeRemark 是
//     整体状态(总是带当前值, 空 = 清空), lines 只列要改的行, 每行四选一
//     discount / dealPrice / giftZeroPrice / useMasterPrice;
//   · 退回 / 确认 QuoteFinanceDecisionRequest{expectedRevision, expectedClaimId, text};
//   · 撤销确认 QuoteActionRequest{expectedRevision}(不认领, 见 [SalesQuoteFinanceAction.reopen])。
// 字段名改动必须两边同改; test/features/finance/quote_finance_contract_fixture_test.dart 用
// 照服务端 record 抄写的 JSON 锁住这里的解析与请求体。
// 金额、价格、折扣一律保留服务端十进制原文(ADR-112), 页面预览见 quote_finance_pricing.dart。
import '../../sales/models/sales_quote_workflow.dart';
import 'quote_finance_pricing.dart';

export '../../sales/models/sales_quote_workflow.dart'
    show SalesQuoteRevision, SalesQuoteRevisionAction;

/// 核价队列分段(GET /sales/quotes/finance-review?state=)。
enum SalesQuoteFinanceState {
  pending('pending'),
  confirmed('confirmed'),
  returned('returned');

  const SalesQuoteFinanceState(this.query);
  final String query;
}

/// 财务在核价详情上能做的动作(服务端 financeActions: edit / return / confirm / reopen)。
enum SalesQuoteFinanceAction {
  edit('edit'),
  returnToSales('return'),
  confirm('confirm'),
  reopen('reopen');

  const SalesQuoteFinanceAction(this.code);
  final String code;

  /// 改价、退回、确认要先认领(服务端核对 expectedClaimId)。撤销确认不认领: 服务端只给
  /// 已核价的报价下发它, 而认领只接受待核价的报价(SalesQuoteFinanceClaimTargetLocks)。
  bool get needsClaim => this != reopen;
}

/// 行的定价来源: 货品资料标价打折 / 财务直接定价。
abstract final class QuotePriceSource {
  static const master = 'MASTER';
  static const finance = 'FINANCE';
}

/// 核价队列一行(服务端 QuoteFinanceListItem)。
class SalesQuoteFinanceListItem {
  const SalesQuoteFinanceListItem({
    required this.quoteId,
    required this.billNo,
    this.billDate,
    this.clientName,
    this.sellerName,
    this.makerName,
    this.submittedAt,
    this.lineCount = 0,
    this.pricePendingCount = 0,
    this.totalOriginal,
    this.clientFileCurrency,
    this.statusBucket,
    this.reviewRevision = 0,
    this.resubmitted = false,
    this.financeReturnReason,
    this.financeReturnedAt,
    this.financeConfirmedAt,
    this.financeConfirmedByName,
    this.convertedOrderNo,
    this.claimedByName,
    this.claimedByMe = false,
  });

  final String quoteId;
  final String billNo;
  final String? billDate;
  final String? clientName;
  final String? sellerName;
  final String? makerName;
  final String? submittedAt;
  final int lineCount;

  /// 还没有单价、需要财务定价的行数。
  final int pricePendingCount;

  /// 报价金额(本币, 服务端十进制原文; 有没定价的行时只含已定价部分)。
  final String? totalOriginal;

  /// 客户文件里的币种(如 USD); 报价本身按本币。
  final String? clientFileCurrency;
  final String? statusBucket;
  final int reviewRevision;

  /// 销售改后重新提交(之前财务确认/退回过)。
  final bool resubmitted;
  final String? financeReturnReason;
  final String? financeReturnedAt;
  final String? financeConfirmedAt;
  final String? financeConfirmedByName;
  final String? convertedOrderNo;

  /// 正在核价的人(有有效认领时); [claimedByMe] = 就是我。
  final String? claimedByName;
  final bool claimedByMe;

  factory SalesQuoteFinanceListItem.fromJson(Map<String, dynamic> json) =>
      SalesQuoteFinanceListItem(
        quoteId: _text(json['id']) ?? '',
        billNo: _text(json['billNo']) ?? '',
        billDate: _text(json['billDate']),
        clientName: _text(json['clientName']),
        sellerName: _text(json['sellerName']),
        makerName: _text(json['makerName']),
        submittedAt: _text(json['submittedAt']),
        lineCount: _int(json['lineCount']) ?? 0,
        pricePendingCount: _int(json['pricePendingCount']) ?? 0,
        totalOriginal: _text(json['totalOriginal']),
        clientFileCurrency: _text(json['clientFileCurrency']),
        statusBucket: _text(json['statusBucket'])?.toUpperCase(),
        reviewRevision: _int(json['reviewRevision']) ?? 0,
        resubmitted: json['resubmitted'] == true,
        financeReturnReason: _text(json['financeReturnReason']),
        financeReturnedAt: _text(json['financeReturnedAt']),
        financeConfirmedAt: _text(json['financeConfirmedAt']),
        financeConfirmedByName: _text(json['financeConfirmedByName']),
        convertedOrderNo: _text(json['convertedOrderNo']),
        claimedByName: _text(json['claimedByName']),
        claimedByMe: json['claimedByMe'] == true,
      );
}

/// 核价明细行(服务端 QuoteFinanceReviewDto.Line)。
class SalesQuoteFinanceLine {
  const SalesQuoteFinanceLine({
    required this.itemId,
    this.lineNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitId,
    this.unitName,
    this.qty,
    this.storedPrice,
    this.priceSource = QuotePriceSource.master,
    this.financePriceByName,
    this.financePriceAt,
    this.currentMasterPrice,
    this.clientPrice,
    this.clientPriceLocal,
    this.dealPrice,
    this.discount,
    this.amount,
    this.fileAmountLocal,
    this.diffToFile,
    this.salesProposedDiscount,
    this.lastFinanceConfirmedDiscount,
    this.changedSinceLastConfirm = false,
    this.clientModel,
    this.clientGoodsName,
    this.remark,
    this.blockingReason,
  });

  final String itemId;
  final int? lineNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;

  /// 单位主键(服务端 Line 目前只给单位名称; 有主键时「合计数量」按主键分组)。
  final String? unitId;
  final String? unitName;
  final String? qty;

  /// 合计数量的分组键: 不同单位的数量绝不相加。
  String? get unitKey => unitId ?? unitName;

  /// 本行已存单价(服务端字段名 listPrice): MASTER 时是提交时冻结的货品标价,
  /// FINANCE 时是财务定的成交单价, 空 = 还没有单价。标价请用 [listPrice]。
  final String? storedPrice;
  final String priceSource;
  final String? financePriceByName;
  final String? financePriceAt;

  /// 货品资料里此刻的标价(财务刚维护过标价时与 [storedPrice] 不同)。
  final String? currentMasterPrice;

  /// 客户文件里的单价(文件币种原币) / 按财务参考汇率折合本币。
  final String? clientPrice;
  final String? clientPriceLocal;

  /// 成交单价 = 单价 × 折扣; 金额 = 数量 × 单价 × 折扣; 与文件差额 = 金额 − 文件金额(本币)。
  final String? dealPrice;
  final String? discount;
  final String? amount;
  final String? fileAmountLocal;
  final String? diffToFile;

  /// 销售最近一次提交时的折扣(对照用)。
  final String? salesProposedDiscount;

  /// 再次提交时，财务上次确认过的折扣；与现值不同的行要标黄提醒。
  final String? lastFinanceConfirmedDiscount;

  /// 服务端判定: 销售这次提交的折扣与上次财务确认的不同。
  final bool changedSinceLastConfirm;
  final String? clientModel;
  final String? clientGoodsName;
  final String? remark;

  /// 确认前必须处理的问题(服务端原文, 空 = 没有)。
  final String? blockingReason;

  bool get isFinancePriced => priceSource == QuotePriceSource.finance;

  /// 冻结的货品标价在用: 按标价打折且已有单价。
  bool get pricedFromFrozenList => !isFinancePriced && storedPrice != null;

  /// 标价 = 反推折扣的基准, 与服务端 applyDealPrice 取同一个: 冻结标价在用时取它,
  /// 否则(财务定价行 / 还没有单价)取货品资料当前标价。
  String? get listPrice =>
      pricedFromFrozenList ? storedPrice : currentMasterPrice;

  /// 有大于 0 的标价(可以按标价打折)。
  bool get hasListPrice => isPositiveDecimal(listPrice);

  /// 货品资料标价已经变了(财务刚维护过), 可「按最新标价刷新」本行单价、折扣不变。
  bool get canRefreshFromMaster =>
      pricedFromFrozenList &&
      isPositiveDecimal(currentMasterPrice) &&
      !sameDecimal(storedPrice, currentMasterPrice);

  /// 按服务端已保存的状态，这一行还不能确认(与服务端 blockingReason 同一口径)：没有单价；
  /// 或单价为 0 而客户文件写了单价、财务又没显式设为赠品/0价(FINANCE 0)。
  bool get needsFinancePrice {
    if (blockingReason != null) return true;
    final sign = quoteDecimalSign(storedPrice);
    if (sign == null) return true;
    return sign == 0 && !isFinancePriced && isPositiveDecimal(clientPrice);
  }

  factory SalesQuoteFinanceLine.fromJson(
    Map<String, dynamic> json,
  ) => SalesQuoteFinanceLine(
    itemId: _text(json['itemId']) ?? '',
    lineNo: _int(json['lineNo']),
    goodsId: _text(json['goodsId']),
    goodsCode: _text(json['goodsCode']),
    goodsName: _text(json['goodsName']),
    colorName: _text(json['colorName']),
    unitId: _text(json['unitId']),
    unitName: _text(json['unitName']),
    qty: _text(json['qty']),
    storedPrice: _text(json['listPrice']),
    priceSource:
        (_text(json['priceSource'])?.toUpperCase() == QuotePriceSource.finance)
        ? QuotePriceSource.finance
        : QuotePriceSource.master,
    financePriceByName: _text(json['financePriceByName']),
    financePriceAt: _text(json['financePriceAt']),
    currentMasterPrice: _text(json['currentMasterPrice']),
    clientPrice: _text(json['clientPrice']),
    clientPriceLocal: _text(json['clientPriceLocal']),
    dealPrice: _text(json['dealPrice']),
    discount: _text(json['discount']),
    amount: _text(json['amount']),
    fileAmountLocal: _text(json['fileAmountLocal']),
    diffToFile: _text(json['diffToFile']),
    salesProposedDiscount: _text(json['salesProposedDiscount']),
    lastFinanceConfirmedDiscount: _text(json['lastFinanceConfirmedDiscount']),
    changedSinceLastConfirm: json['changedSinceLastConfirm'] == true,
    clientModel: _text(json['clientModel']),
    clientGoodsName: _text(json['clientGoodsName']),
    remark: _text(json['remark']),
    blockingReason: _text(json['blockingReason']),
  );
}

/// 核价详情(GET /sales/quotes/{id}/finance-review, 服务端 QuoteFinanceReviewDto)。
class SalesQuoteFinanceReview {
  const SalesQuoteFinanceReview({
    required this.quoteId,
    required this.billNo,
    this.billDate,
    this.clientId,
    this.clientName,
    this.clientCode,
    this.makerName,
    this.sellerName,
    this.currencyName,
    this.baseCurrency = true,
    this.settlementMethodId,
    this.settlementMethodName,
    this.validUntil,
    this.deliverDate,
    this.contractNo,
    this.remark,
    this.clientFileCurrency,
    this.financeRate,
    this.financeRateMissing = false,
    this.status,
    this.statusBucket,
    this.reviewRevision = 0,
    this.submittedAt,
    this.submittedByName,
    this.financeRemark,
    this.financeReturnReason,
    this.financeReturnedAt,
    this.financeReturnedByName,
    this.financeConfirmedAt,
    this.financeConfirmedByName,
    this.totalOriginal,
    this.fileTotalLocal,
    this.pricePendingCount = 0,
    this.blockingLineCount = 0,
    this.resubmitted = false,
    this.convertedOrderNo,
    this.canMaintainGoodsPrice = false,
    this.financeActions = const {},
    this.claimType,
    this.lines = const [],
    this.revisions = const [],
  });

  final String quoteId;
  final String billNo;
  final String? billDate;
  final String? clientId;
  final String? clientName;
  final String? clientCode;
  final String? makerName;
  final String? sellerName;

  /// 报价币种名称(本期只允许本币)。
  final String? currencyName;
  final bool baseCurrency;
  final String? settlementMethodId;
  final String? settlementMethodName;
  final String? validUntil;
  final String? deliverDate;
  final String? contractNo;
  final String? remark;

  /// 客户文件里的币种(如 USD)与财务参考汇率(文件币种 → 本币; 文件就是本币时为空)。
  final String? clientFileCurrency;
  final String? financeRate;

  /// 文件是外币但还没有财务参考汇率(折合本币、与文件差额都空着)。
  final bool financeRateMissing;
  final int? status;
  final String? statusBucket;
  final int reviewRevision;
  final String? submittedAt;
  final String? submittedByName;
  final String? financeRemark;
  final String? financeReturnReason;
  final String? financeReturnedAt;
  final String? financeReturnedByName;
  final String? financeConfirmedAt;
  final String? financeConfirmedByName;
  final String? totalOriginal;
  final String? fileTotalLocal;
  final int pricePendingCount;
  final int blockingLineCount;

  /// 销售改后重新提交(之前财务确认或退回过)。
  final bool resubmitted;
  final String? convertedOrderNo;

  /// 服务端能力位：当前人能去货品资料维护标价(持 goods:price:edit)。
  final bool canMaintainGoodsPrice;

  /// 归一后的动作码([normalizeQuoteActionCode]): edit / return / confirm / reopen。
  final Set<String> financeActions;

  /// 认领目标类型(服务端下发, 应为 SALES_QUOTE_FINANCE_REVIEW)。
  final String? claimType;
  final List<SalesQuoteFinanceLine> lines;
  final List<SalesQuoteRevision> revisions;

  bool allows(SalesQuoteFinanceAction action) =>
      financeActions.contains(normalizeQuoteActionCode(action.code));

  /// 有任一核价动作可做(没有 = 只能查看)。
  bool get hasFinanceActions => SalesQuoteFinanceAction.values.any(allows);

  /// 需要先认领的动作(改价 / 退回 / 确认)任一可做; 只剩撤销确认时不认领。
  bool get needsClaim => SalesQuoteFinanceAction.values.any(
    (action) => action.needsClaim && allows(action),
  );

  factory SalesQuoteFinanceReview.fromJson(Map<String, dynamic> json) {
    final rawActions = json['financeActions'];
    final rawLines = json['lines'];
    return SalesQuoteFinanceReview(
      quoteId: _text(json['id']) ?? '',
      billNo: _text(json['billNo']) ?? '',
      billDate: _text(json['billDate']),
      clientId: _text(json['clientId']),
      clientName: _text(json['clientName']),
      clientCode: _text(json['clientCode']),
      makerName: _text(json['makerName']),
      sellerName: _text(json['sellerName']),
      currencyName: _text(json['currencyName']),
      baseCurrency: json['baseCurrency'] != false,
      settlementMethodId: _text(json['settlementMethodId']),
      settlementMethodName: _text(json['settlementMethodName']),
      validUntil: _text(json['validUntil']),
      deliverDate: _text(json['deliverDate']),
      contractNo: _text(json['contractNo']),
      remark: _text(json['remark']),
      clientFileCurrency: _text(json['clientFileCurrency']),
      financeRate: _text(json['financeRate']),
      financeRateMissing: json['financeRateMissing'] == true,
      status: _int(json['status']),
      statusBucket: _text(json['statusBucket'])?.toUpperCase(),
      reviewRevision: _int(json['reviewRevision']) ?? 0,
      submittedAt: _text(json['submittedAt']),
      submittedByName: _text(json['submittedByName']),
      financeRemark: _text(json['financeRemark']),
      financeReturnReason: _text(json['financeReturnReason']),
      financeReturnedAt: _text(json['financeReturnedAt']),
      financeReturnedByName: _text(json['financeReturnedByName']),
      financeConfirmedAt: _text(json['financeConfirmedAt']),
      financeConfirmedByName: _text(json['financeConfirmedByName']),
      totalOriginal: _text(json['totalOriginal']),
      fileTotalLocal: _text(json['fileTotalLocal']),
      pricePendingCount: _int(json['pricePendingCount']) ?? 0,
      blockingLineCount: _int(json['blockingLineCount']) ?? 0,
      resubmitted: json['resubmitted'] == true,
      convertedOrderNo: _text(json['convertedOrderNo']),
      canMaintainGoodsPrice: json['canMaintainGoodsPrice'] == true,
      financeActions: rawActions is List
          ? {
              for (final action in rawActions)
                if (action != null) normalizeQuoteActionCode(action.toString()),
            }
          : const {},
      claimType: _text(json['claimType']),
      lines: rawLines is List
          ? rawLines
                .whereType<Map<Object?, Object?>>()
                .map(
                  (e) =>
                      SalesQuoteFinanceLine.fromJson(e.cast<String, dynamic>()),
                )
                .toList(growable: false)
          : const [],
      revisions: SalesQuoteRevision.listFromJson(json['revisions']),
    );
  }
}

/// 一行的核价修改(PUT /sales/quotes/{id}/finance 的 lines[], 服务端 QuoteFinanceEditRequest.Line)。
///
/// 每行只能四选一:
///   · [SalesQuoteFinanceLineEdit.discount] —— 直接核定 4 位小数折扣(本行按冻结标价打折);
///   · [SalesQuoteFinanceLineEdit.dealPrice] —— 填成交单价, 服务端按标价反推折扣; 没有标价或
///     高于标价时改为财务定价(单价 = 成交单价, 折扣 1);
///   · [SalesQuoteFinanceLineEdit.giftZeroPrice] —— 赠品/0价(财务定价 0);
///   · [SalesQuoteFinanceLineEdit.useMasterPrice] —— 按货品资料最新标价刷新单价, 折扣不变。
class SalesQuoteFinanceLineEdit {
  const SalesQuoteFinanceLineEdit.discount({
    required this.itemId,
    required String this.discount,
  }) : dealPrice = null,
       giftZeroPrice = false,
       useMasterPrice = false;

  const SalesQuoteFinanceLineEdit.dealPrice({
    required this.itemId,
    required String this.dealPrice,
  }) : discount = null,
       giftZeroPrice = false,
       useMasterPrice = false;

  const SalesQuoteFinanceLineEdit.giftZeroPrice({required this.itemId})
    : discount = null,
      dealPrice = null,
      giftZeroPrice = true,
      useMasterPrice = false;

  const SalesQuoteFinanceLineEdit.useMasterPrice({required this.itemId})
    : discount = null,
      dealPrice = null,
      giftZeroPrice = false,
      useMasterPrice = true;

  final String itemId;
  final String? discount;
  final String? dealPrice;
  final bool giftZeroPrice;
  final bool useMasterPrice;

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'discount': ?discount,
    'dealPrice': ?dealPrice,
    if (giftZeroPrice) 'giftZeroPrice': true,
    if (useMasterPrice) 'useMasterPrice': true,
  };
}

/// 核价保存请求的表头部分: 整体状态, 页面总是带上当前值(null = 清空, 不是「不改」)。
class SalesQuoteFinanceHeader {
  const SalesQuoteFinanceHeader({
    this.validUntil,
    this.settlementMethodId,
    this.financeRemark,
  });

  /// yyyy-MM-dd。
  final String? validUntil;
  final String? settlementMethodId;
  final String? financeRemark;

  Map<String, dynamic> toJson() {
    final remark = financeRemark?.trim();
    return {
      'validUntil': validUntil,
      'settlementMethodId': settlementMethodId,
      'financeRemark': remark == null || remark.isEmpty ? null : remark,
    };
  }
}

String? _text(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _int(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
