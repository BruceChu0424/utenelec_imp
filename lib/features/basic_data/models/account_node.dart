// 账户主档模型（对应后端 AccountListItem / AccountDetail / AccountFacets）。
//
// 扁平主档（无分类树），业务字段：编号/名称/银行账号/account_type(7 类)/币种/期初/累计收/累计付/
// 当前余额/状态 + legacy_id。account_type 取值：BANK/CASH/CHECK/FOREIGN_CHECK/THIRD_PARTY/OFFSHORE/GENERAL。
// 数值字段走 (json['x'] as num?)，避免后端 BigDecimal 序列化成 String/null 时 cast 崩溃。
//
// 端点路径不进 api_endpoints.dart（由用户统一接线），先在本仓文件顶部常量化。
// 后端：/api/master/accounts（GET/POST）+ /{id}（GET/PUT/DELETE）+ /facets + /dict。

import 'master_facet.dart';

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
    this.initBalance,
    this.receiptsTotal,
    this.paymentsTotal,
    this.balanceCurrent,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final String? bankAccountNo;
  final String? accountType;
  final String? currencyId;
  final double? initBalance;
  final double? receiptsTotal;
  final double? paymentsTotal;
  final double? balanceCurrent;
  final String? status;
  final int? legacyId;

  factory AccountListItem.fromJson(Map<String, dynamic> json) => AccountListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        bankAccountNo: json['bankAccountNo'] as String?,
        accountType: json['accountType'] as String?,
        currencyId: json['currencyId'] as String?,
        initBalance: (json['initBalance'] as num?)?.toDouble(),
        receiptsTotal: (json['receiptsTotal'] as num?)?.toDouble(),
        paymentsTotal: (json['paymentsTotal'] as num?)?.toDouble(),
        balanceCurrent: (json['balanceCurrent'] as num?)?.toDouble(),
        status: json['status'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

/// 账户详情（与列表项同字段，另带 parentLegacyId/styleLegacyId/autoCreated）。
class AccountDetail {
  const AccountDetail({
    required this.id,
    this.code,
    this.name,
    this.bankAccountNo,
    this.accountType,
    this.currencyId,
    this.initBalance,
    this.receiptsTotal,
    this.paymentsTotal,
    this.balanceCurrent,
    this.parentLegacyId,
    this.styleLegacyId,
    this.status,
    this.autoCreated = false,
    this.legacyId,
  });

  final String id;
  final String? code;
  final String? name;
  final String? bankAccountNo;
  final String? accountType;
  final String? currencyId;
  final double? initBalance;
  final double? receiptsTotal;
  final double? paymentsTotal;
  final double? balanceCurrent;
  final int? parentLegacyId;
  final int? styleLegacyId;
  final String? status;
  final bool autoCreated;
  final int? legacyId;

  factory AccountDetail.fromJson(Map<String, dynamic> json) => AccountDetail(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        bankAccountNo: json['bankAccountNo'] as String?,
        accountType: json['accountType'] as String?,
        currencyId: json['currencyId'] as String?,
        initBalance: (json['initBalance'] as num?)?.toDouble(),
        receiptsTotal: (json['receiptsTotal'] as num?)?.toDouble(),
        paymentsTotal: (json['paymentsTotal'] as num?)?.toDouble(),
        balanceCurrent: (json['balanceCurrent'] as num?)?.toDouble(),
        parentLegacyId: (json['parentLegacyId'] as num?)?.toInt(),
        styleLegacyId: (json['styleLegacyId'] as num?)?.toInt(),
        status: json['status'] as String?,
        autoCreated: (json['autoCreated'] as bool?) ?? false,
        legacyId: (json['legacyId'] as num?)?.toInt(),
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
              .map((e) => MasterFacetBucket.fromJson(e as Map<String, dynamic>))
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
