// 账户主档模型（对应后端 AccountListItem / AccountDetail / AccountFacets）。
//
// 扁平主档（无分类树），业务字段：编号/名称/银行账号/account_type(7 类)/币种/期初/累计收/累计付/
// 当前余额/状态 + legacy_id。account_type 取值：BANK/CASH/CHECK/FOREIGN_CHECK/THIRD_PARTY/OFFSHORE/GENERAL。
// 数值字段走 (json['x'] as num?)，避免后端 BigDecimal 序列化成 String/null 时 cast 崩溃。
//
// 端点路径不进 api_endpoints.dart（由用户统一接线），先在本仓文件顶部常量化。
// 后端：/api/master/accounts（GET/POST）+ /{id}（GET/PUT/DELETE）+ /facets + /dict。

import 'master_facet.dart';
import '../../../shared/formatters/exact_decimal.dart';

/// 账户类型枚举（与后端 AccountType 对齐）。value 为持久化字符串，label 为中文展示。
enum AccountType {
  bank('BANK', '银行'),
  cash('CASH', '现金'),
  check('CHECK', '支票'),
  foreignCheck('FOREIGN_CHECK', '外来支票'),
  thirdParty('THIRD_PARTY', '第三方'),
  offshore('OFFSHORE', '境外'),
  general('GENERAL', '一般');

  const AccountType(this.value, this.label);
  final String value;
  final String label;

  static AccountType? byValue(String? v) {
    if (v == null) return null;
    for (final t in AccountType.values) {
      if (t.value == v) return t;
    }
    return null;
  }

  /// 展示文案（未知值回退原字符串，避免老库脏数据丢字）。
  static String labelOf(String? v) {
    final t = byValue(v);
    return t?.label ?? (v ?? '');
  }
}

class AccountListItem {
  const AccountListItem({
    required this.id,
    this.code,
    this.name,
    this.bankAccountNo,
    this.accountType,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.exchangeRate,
    this.exchangeRateText,
    this.baseCurrency = false,
    this.initBalance,
    this.initBalanceText,
    this.receiptsTotal,
    this.receiptsTotalText,
    this.paymentsTotal,
    this.paymentsTotalText,
    this.adjustmentsTotal,
    this.adjustmentsTotalText,
    this.balanceCurrent,
    this.balanceCurrentText,
    this.balanceFloor,
    this.balanceFloorText,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final String? bankAccountNo;
  final String? accountType;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final double? exchangeRate;
  final String? exchangeRateText;
  final bool baseCurrency;
  final double? initBalance;
  final String? initBalanceText;
  final double? receiptsTotal;
  final String? receiptsTotalText;
  final double? paymentsTotal;
  final String? paymentsTotalText;
  final double? adjustmentsTotal;
  final String? adjustmentsTotalText;
  final double? balanceCurrent;
  final String? balanceCurrentText;
  final double? balanceFloor;
  final String? balanceFloorText;
  final String? status;
  final int? legacyId;

  factory AccountListItem.fromJson(Map<String, dynamic> json) =>
      AccountListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        bankAccountNo: json['bankAccountNo'] as String?,
        accountType: json['accountType'] as String?,
        currencyId: json['currencyId'] as String?,
        currencyCode: json['currencyCode'] as String?,
        currencyName: json['currencyName'] as String?,
        exchangeRate: _decimal(json['exchangeRate']),
        exchangeRateText: _decimalText(json, 'exchangeRate'),
        baseCurrency: json['baseCurrency'] as bool? ?? false,
        initBalance: _decimal(json['initBalance']),
        initBalanceText: _decimalText(json, 'initBalance'),
        receiptsTotal: _decimal(json['receiptsTotal']),
        receiptsTotalText: _decimalText(json, 'receiptsTotal'),
        paymentsTotal: _decimal(json['paymentsTotal']),
        paymentsTotalText: _decimalText(json, 'paymentsTotal'),
        adjustmentsTotal: _decimal(json['adjustmentsTotal']),
        adjustmentsTotalText: _decimalText(json, 'adjustmentsTotal'),
        balanceCurrent: _decimal(json['balanceCurrent']),
        balanceCurrentText: _decimalText(json, 'balanceCurrent'),
        balanceFloor: _decimal(json['balanceFloor']),
        balanceFloorText: _decimalText(json, 'balanceFloor'),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

/// 账户详情（styleId 为会计科目 UUID 真源，styleLegacyId 仅兼容旧数据）。
class AccountDetail {
  const AccountDetail({
    required this.id,
    this.code,
    this.name,
    this.bankAccountNo,
    this.accountType,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.exchangeRate,
    this.exchangeRateText,
    this.baseCurrency = false,
    this.initBalance,
    this.initBalanceText,
    this.receiptsTotal,
    this.receiptsTotalText,
    this.paymentsTotal,
    this.paymentsTotalText,
    this.adjustmentsTotal,
    this.adjustmentsTotalText,
    this.balanceCurrent,
    this.balanceCurrentText,
    this.balanceFloor,
    this.balanceFloorText,
    this.parentLegacyId,
    this.styleLegacyId,
    this.styleId,
    this.status,
    this.autoCreated = false,
    this.legacyId,
    this.flowBalance,
    this.flowBalanceText,
    this.balanceDifference,
    this.balanceDifferenceText,
    this.flowIntegrity,
    this.activeFlowCount,
    this.latestFlowAt,
  });

  final String id;
  final String? code;
  final String? name;
  final String? bankAccountNo;
  final String? accountType;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final double? exchangeRate;
  final String? exchangeRateText;
  final bool baseCurrency;
  final double? initBalance;
  final String? initBalanceText;
  final double? receiptsTotal;
  final String? receiptsTotalText;
  final double? paymentsTotal;
  final String? paymentsTotalText;
  final double? adjustmentsTotal;
  final String? adjustmentsTotalText;
  final double? balanceCurrent;
  final String? balanceCurrentText;
  final double? balanceFloor;
  final String? balanceFloorText;
  final int? parentLegacyId;
  final int? styleLegacyId;
  final String? styleId;
  final String? status;
  final bool autoCreated;
  final int? legacyId;
  final double? flowBalance;
  final String? flowBalanceText;
  final double? balanceDifference;
  final String? balanceDifferenceText;
  final bool? flowIntegrity;
  final int? activeFlowCount;
  final String? latestFlowAt;

  factory AccountDetail.fromJson(Map<String, dynamic> json) => AccountDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    bankAccountNo: json['bankAccountNo'] as String?,
    accountType: json['accountType'] as String?,
    currencyId: json['currencyId'] as String?,
    currencyCode: json['currencyCode'] as String?,
    currencyName: json['currencyName'] as String?,
    exchangeRate: _decimal(json['exchangeRate']),
    exchangeRateText: _decimalText(json, 'exchangeRate'),
    baseCurrency: json['baseCurrency'] as bool? ?? false,
    initBalance: _decimal(json['initBalance']),
    initBalanceText: _decimalText(json, 'initBalance'),
    receiptsTotal: _decimal(json['receiptsTotal']),
    receiptsTotalText: _decimalText(json, 'receiptsTotal'),
    paymentsTotal: _decimal(json['paymentsTotal']),
    paymentsTotalText: _decimalText(json, 'paymentsTotal'),
    adjustmentsTotal: _decimal(json['adjustmentsTotal']),
    adjustmentsTotalText: _decimalText(json, 'adjustmentsTotal'),
    balanceCurrent: _decimal(json['balanceCurrent']),
    balanceCurrentText: _decimalText(json, 'balanceCurrent'),
    balanceFloor: _decimal(json['balanceFloor']),
    balanceFloorText: _decimalText(json, 'balanceFloor'),
    parentLegacyId: (json['parentLegacyId'] as num?)?.toInt(),
    styleLegacyId: (json['styleLegacyId'] as num?)?.toInt(),
    styleId: json['styleId'] as String?,
    status: json['status'] as String?,
    autoCreated: (json['autoCreated'] as bool?) ?? false,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    flowBalance: _decimal(json['flowBalance']),
    flowBalanceText: _decimalText(json, 'flowBalance'),
    balanceDifference: _decimal(json['balanceDifference']),
    balanceDifferenceText: _decimalText(json, 'balanceDifference'),
    flowIntegrity: json['flowIntegrity'] as bool?,
    activeFlowCount: (json['activeFlowCount'] as num?)?.toInt(),
    latestFlowAt: json['latestFlowAt']?.toString(),
  );
}

/// 字段 facet 结果：accountType/status/currencyId 的可选值桶 + 各字段空值计数。
/// 金额字段（init/receipts/payments/balance）不进 facet，仅列表/详情展示。
class AccountFacets {
  const AccountFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = ['accountType', 'status', 'currencyId'];

  factory AccountFacets.fromJson(Map<String, dynamic> json) {
    final fields = <String, List<MasterFacetBucket>>{};
    for (final k in _keys) {
      final list = json[k];
      fields[k] = list is List
          ? list
                .map(
                  (e) => MasterFacetBucket.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : const [];
    }
    final ncRaw = json['nullCounts'];
    final nullCounts = <String, int>{};
    if (ncRaw is Map) {
      ncRaw.forEach((k, v) {
        nullCounts[k.toString()] = (v is num ? v.toInt() : 0);
      });
    }
    return AccountFacets(fields: fields, nullCounts: nullCounts);
  }
}

/// 账户资料页顶部概览。金额永远按 [currencies] 分币种展示，不提供跨币种原额合计。
class AccountSummary {
  const AccountSummary({
    required this.totalAccounts,
    required this.activeAccounts,
    required this.disabledAccounts,
    required this.warningAccounts,
    required this.negativeAccounts,
    required this.currencies,
  });

  final int totalAccounts;
  final int activeAccounts;
  final int disabledAccounts;
  final int warningAccounts;
  final int negativeAccounts;
  final List<AccountCurrencySummary> currencies;

  factory AccountSummary.fromJson(Map<String, dynamic> json) => AccountSummary(
    totalAccounts: _integer(json['totalAccounts']),
    activeAccounts: _integer(json['activeAccounts']),
    disabledAccounts: _integer(json['disabledAccounts']),
    warningAccounts: _integer(json['warningAccounts']),
    negativeAccounts: _integer(json['negativeAccounts']),
    currencies: [
      for (final raw in json['currencies'] as List<dynamic>? ?? const [])
        AccountCurrencySummary.fromJson(raw as Map<String, dynamic>),
    ],
  );
}

class AccountCurrencySummary {
  const AccountCurrencySummary({
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    required this.accountCount,
    required this.activeAccountCount,
    this.balanceTotal,
    this.balanceTotalText,
    required this.warningCount,
    required this.negativeCount,
  });

  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final int accountCount;
  final int activeAccountCount;
  final double? balanceTotal;
  final String? balanceTotalText;
  final int warningCount;
  final int negativeCount;

  factory AccountCurrencySummary.fromJson(Map<String, dynamic> json) =>
      AccountCurrencySummary(
        currencyId: json['currencyId'] as String?,
        currencyCode: json['currencyCode'] as String?,
        currencyName: json['currencyName'] as String?,
        accountCount: _integer(json['accountCount']),
        activeAccountCount: _integer(json['activeAccountCount']),
        balanceTotal: _decimal(json['balanceTotal']),
        balanceTotalText: _decimalText(json, 'balanceTotal'),
        warningCount: _integer(json['warningCount']),
        negativeCount: _integer(json['negativeCount']),
      );
}

/// 账户详情页流水。金额保留后端 BigDecimal 的数值语义；UI 只在展示边界格式化。
class AccountStatementRow {
  const AccountStatementRow({
    this.billDate,
    this.billNo,
    this.checkNo,
    this.summary,
    this.counterpartName,
    this.source,
    this.sourceDocType,
    this.sourceDocId,
    this.settledDate,
    this.inAmount,
    this.inAmountText,
    this.outAmount,
    this.outAmountText,
    this.balance,
    this.balanceText,
    this.entryKind,
    this.reversalOfId,
    this.entryId,
    this.postingSeq,
  });

  final String? billDate;
  final String? billNo;
  final String? checkNo;
  final String? summary;
  final String? counterpartName;
  final String? source;
  final String? sourceDocType;
  final String? sourceDocId;
  final String? settledDate;
  final double? inAmount;
  final String? inAmountText;
  final double? outAmount;
  final String? outAmountText;
  final double? balance;
  final String? balanceText;
  final String? entryKind;
  final String? reversalOfId;
  final String? entryId;
  final int? postingSeq;

  factory AccountStatementRow.fromJson(Map<String, dynamic> json) =>
      AccountStatementRow(
        billDate: json['billDate']?.toString(),
        billNo: json['billNo']?.toString(),
        checkNo: json['checkNo']?.toString(),
        summary: json['summary']?.toString(),
        counterpartName: json['counterpartName']?.toString(),
        source: json['source']?.toString(),
        sourceDocType: json['sourceDocType']?.toString(),
        sourceDocId: json['sourceDocId']?.toString(),
        settledDate: json['settledDate']?.toString(),
        inAmount: _decimal(json['inAmount']),
        inAmountText: _decimalText(json, 'inAmount'),
        outAmount: _decimal(json['outAmount']),
        outAmountText: _decimalText(json, 'outAmount'),
        balance: _decimal(json['balance']),
        balanceText: _decimalText(json, 'balance'),
        entryKind: json['entryKind']?.toString(),
        reversalOfId: json['reversalOfId']?.toString(),
        entryId: json['entryId']?.toString(),
        postingSeq: (json['postingSeq'] as num?)?.toInt(),
      );
}

class AccountStatementPage {
  const AccountStatementPage({
    required this.rows,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<AccountStatementRow> rows;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory AccountStatementPage.fromJson(Map<String, dynamic> json) =>
      AccountStatementPage(
        rows: [
          for (final raw in json['rows'] as List<dynamic>? ?? const [])
            AccountStatementRow.fromJson(raw as Map<String, dynamic>),
        ],
        page: _integer(json['page'], fallback: 1),
        size: _integer(json['size'], fallback: 50),
        total: _integer(json['total']),
        totalPages: _integer(json['totalPages']),
      );
}

enum AccountBalanceAdjustmentScope {
  full('FULL'),
  selected('SELECTED');

  const AccountBalanceAdjustmentScope(this.value);
  final String value;
}

class AccountBalanceAdjustmentInput {
  const AccountBalanceAdjustmentInput({
    required this.accountId,
    required this.expectedBalance,
    required this.targetBalance,
    this.localDelta,
  });

  final String accountId;
  final String expectedBalance;
  final String targetBalance;

  /// 本位币调账额，仅用于总账开账/调整，不改变账户原币余额。
  ///
  /// 人民币账户与原币无变化的外币账户可不传；外币原币余额发生变化时
  /// 由财务明确填写，禁止从币种主档参考汇率推算。
  final String? localDelta;

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'expectedBalance': expectedBalance,
    'targetBalance': targetBalance,
    if (localDelta != null) 'localDelta': localDelta,
  };
}

class AccountBalanceAdjustmentBatchResult {
  const AccountBalanceAdjustmentBatchResult({
    required this.id,
    this.batchNo,
    this.scope,
    this.effectiveDate,
    this.reason,
    required this.itemCount,
    required this.changedCount,
    this.totalIncreaseLocal,
    this.totalIncreaseLocalText,
    this.totalDecreaseLocal,
    this.totalDecreaseLocalText,
    this.actorId,
    this.createdAt,
    required this.items,
  });

  final String id;
  final String? batchNo;
  final String? scope;
  final String? effectiveDate;
  final String? reason;
  final int itemCount;
  final int changedCount;
  final double? totalIncreaseLocal;
  final String? totalIncreaseLocalText;
  final double? totalDecreaseLocal;
  final String? totalDecreaseLocalText;
  final String? actorId;
  final String? createdAt;
  final List<AccountBalanceAdjustmentResultItem> items;

  factory AccountBalanceAdjustmentBatchResult.fromJson(
    Map<String, dynamic> json,
  ) => AccountBalanceAdjustmentBatchResult(
    id: json['id'] as String,
    batchNo: json['batchNo'] as String?,
    scope: json['scope'] as String?,
    effectiveDate: json['effectiveDate']?.toString(),
    reason: json['reason'] as String?,
    itemCount: _integer(json['itemCount']),
    changedCount: _integer(json['changedCount']),
    totalIncreaseLocal: _decimal(json['totalIncreaseLocal']),
    totalIncreaseLocalText: _decimalText(json, 'totalIncreaseLocal'),
    totalDecreaseLocal: _decimal(json['totalDecreaseLocal']),
    totalDecreaseLocalText: _decimalText(json, 'totalDecreaseLocal'),
    actorId: json['actorId'] as String?,
    createdAt: json['createdAt']?.toString(),
    items: [
      for (final raw in json['items'] as List<dynamic>? ?? const [])
        AccountBalanceAdjustmentResultItem.fromJson(
          raw as Map<String, dynamic>,
        ),
    ],
  );
}

class AccountBalanceAdjustmentResultItem {
  const AccountBalanceAdjustmentResultItem({
    required this.id,
    required this.accountId,
    this.accountCode,
    this.accountName,
    this.currencyId,
    this.currencyCode,
    this.currencyName,
    this.exchangeRate,
    this.exchangeRateText,
    this.expectedBalance,
    this.expectedBalanceText,
    this.targetBalance,
    this.targetBalanceText,
    this.delta,
    this.deltaText,
    this.deltaLocal,
    this.deltaLocalText,
    this.localAmountBasis,
    required this.verified,
  });

  final String id;
  final String accountId;
  final String? accountCode;
  final String? accountName;
  final String? currencyId;
  final String? currencyCode;
  final String? currencyName;
  final double? exchangeRate;
  final String? exchangeRateText;
  final double? expectedBalance;
  final String? expectedBalanceText;
  final double? targetBalance;
  final String? targetBalanceText;
  final double? delta;
  final String? deltaText;
  final double? deltaLocal;
  final String? deltaLocalText;
  final String? localAmountBasis;
  final bool verified;

  factory AccountBalanceAdjustmentResultItem.fromJson(
    Map<String, dynamic> json,
  ) => AccountBalanceAdjustmentResultItem(
    id: json['id'] as String,
    accountId: json['accountId'] as String,
    accountCode: json['accountCode'] as String?,
    accountName: json['accountName'] as String?,
    currencyId: json['currencyId'] as String?,
    currencyCode: json['currencyCode'] as String?,
    currencyName: json['currencyName'] as String?,
    exchangeRate: _decimal(json['exchangeRate']),
    exchangeRateText: _decimalText(json, 'exchangeRate'),
    expectedBalance: _decimal(json['expectedBalance']),
    expectedBalanceText: _decimalText(json, 'expectedBalance'),
    targetBalance: _decimal(json['targetBalance']),
    targetBalanceText: _decimalText(json, 'targetBalance'),
    delta: _decimal(json['delta']),
    deltaText: _decimalText(json, 'delta'),
    deltaLocal: _decimal(json['deltaLocal']),
    deltaLocalText: _decimalText(json, 'deltaLocal'),
    localAmountBasis: json['localAmountBasis'] as String?,
    verified: json['verified'] as bool? ?? false,
  );
}

double? _decimal(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

int _integer(Object? raw, {int fallback = 0}) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? fallback;
  return fallback;
}

String? _decimalText(Map<String, dynamic> json, String key) =>
    financeExactDecimal(json['${key}Text'] ?? json[key]);
