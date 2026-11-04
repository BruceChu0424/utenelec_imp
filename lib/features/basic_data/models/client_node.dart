// 客户主档模型（对应后端 ClientListItem / ClientDetail / ClientFacets）。
//
// 数值字段一律走 (json['x'] as num?)?.toInt()/toDouble()，避免 int/double 被后端
// 序列化成 String（或 null）时直接 cast 崩溃——老库迁移常踩这个坑。
// 原数字字段保留兼容；编辑与精确显示优先使用服务端 Exact 文本。
// tday 为 Integer（TDay 结算天数）。
//
// 后端对 fullName / clientXz / placeId / empId / legalPerson / bankAccount / taxId
// 显式 @JsonProperty 钉死 key；fromJson 仍兼容小写兜底，防 Jackson bean 命名歧义。

import 'master_facet.dart';
import '../../../core/formatters/exact_number_text.dart';

String? _clientRecordedNumber(Map<String, dynamic> json, String key) {
  final exactKey = '${key}Exact';
  if (json.containsKey(exactKey)) return exactNumberText(json[exactKey]) ?? '';
  return exactNumberText(json[key] ?? json['${key}DisplayText']);
}

double? _clientLegacyNumber(Object? value) {
  final number = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  return number != null && number.isFinite ? number : null;
}

/// 客户列表项（覆盖表格 23 列中 21 个有 DB 列的字段）。
class ClientListItem {
  const ClientListItem({
    required this.id,
    this.code,
    this.name,
    this.fullName,
    this.nameEn,
    this.clientXz,
    this.tday,
    this.region,
    this.placeId,
    this.empId,
    this.legalPerson,
    this.linkman,
    this.mobile,
    this.phone,
    this.phone2,
    this.fax,
    this.postcode,
    this.address,
    this.bank,
    this.bankAccount,
    this.taxId,
    this.credit,
    this.creditExactText,
    this.creditFloor,
    this.creditFloorExactText,
    this.creditDisplayText,
    this.creditFloorDisplayText,
    this.website,
    this.status,
    this.legacyId,
    this.categoryId,
    this.ownerEmployeeId,
    this.ownerEmployeeName,
    this.ownerEmployeeIds = const [],
    this.ownerEmployeeNames = const [],
    this.defaultSettlementMethodId,
    this.defaultSettlementMethodName,
    this.defaultShipmentPolicy,
    this.defaultCurrencyId,
    this.defaultCurrencyName,
    this.writable = false,
    this.financialWritable = false,
    this.accessManageable = false,
    this.version,
  });

  /// 乐观锁版本(ADR-111)：行启停、批量启停/删除直接回传比对，不必先拉详情。
  final int? version;

  final String id;
  final String? code; // 客户编码（Number）
  final String? name; // 客户简称（Client_Name）
  final String? fullName; // 客户全称（Full_Name）

  /// Company name in English or another foreign language (clients.name_en,
  /// ADR-134); customer-file intake matches clients by it.
  final String? nameEn;
  final String? clientXz; // 客户性质（ClientXZ）
  final int? tday; // 信用天数（TDay 结算天数）
  final String? region; // 区域（QYName）
  final String? placeId; // 所属地区（PlaceID）
  final String? empId; // 业务员（Emp_ID）
  final String? legalPerson; // 法人代表（Juri_Per）
  final String? linkman; // 联系人（Link_Man）
  final String? mobile; // 手机（Mobile）
  final String? phone; // 联系电话（Phone）
  final String? phone2; // 备用电话（Phone2）
  final String? fax; // 传真（Fax）
  final String? postcode; // 邮编（Post）
  final String? address; // 地址（Link_Addr）
  final String? bank; // 开户银行（Client_Bank）
  final String? bankAccount; // 银行账号（Client_BankNo）
  final String? taxId; // 纳税号（Tax_ID）
  final double? credit; // 信誉额度（Credit）
  final String? creditExactText;
  final double? creditFloor; // 铺底额（未设置时服务端返回 0）
  final String? creditFloorExactText;
  final String? creditDisplayText;
  final String? creditFloorDisplayText;
  final String? website; // 网址（Http）
  final String? status; // 状态（使用/禁用，详情用，不进表格列）
  final int? legacyId;
  final String? categoryId; // 所属分类 id（客户资料页"搜客户定位分类"用）
  final String? ownerEmployeeId; // 当前负责人 UUID 真源
  final List<String> ownerEmployeeIds;
  final List<String> ownerEmployeeNames;
  String get ownersLabel => ownerEmployeeNames.isNotEmpty
      ? ownerEmployeeNames.join('、')
      : ownerEmployeeName ?? '未分配';
  final String? ownerEmployeeName; // 当前负责人显示名
  final String? defaultSettlementMethodId;
  final String? defaultSettlementMethodName;

  /// 默认销售条款（V592 单一事实源）：新建销售订货单预填；每次下单自动写回最新选择。
  final String? defaultShipmentPolicy;
  final String? defaultCurrencyId;
  final String? defaultCurrencyName;
  final bool financialWritable;
  final bool writable; // 对象范围允许维护；额外查看/单客户共享为 false
  final bool accessManageable; // 服务端已合并 client:assign 与对象范围判断

  factory ClientListItem.fromJson(Map<String, dynamic> json) => ClientListItem(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    // 后端 @JsonProperty("fullName") 输出 fullName；兼容小写兜底。
    fullName: (json['fullName'] ?? json['fullname']) as String?,
    nameEn: json['nameEn'] as String?,
    clientXz: (json['clientXz'] ?? json['clientxz']) as String?,
    tday: (json['tday'] as num?)?.toInt(),
    region: json['region'] as String?,
    placeId: (json['placeId'] ?? json['placeid']) as String?,
    empId: (json['empId'] ?? json['empid']) as String?,
    legalPerson: (json['legalPerson'] ?? json['legalperson']) as String?,
    linkman: json['linkman'] as String?,
    mobile: json['mobile'] as String?,
    phone: json['phone'] as String?,
    phone2: json['phone2'] as String?,
    fax: json['fax'] as String?,
    postcode: json['postcode'] as String?,
    address: json['address'] as String?,
    bank: json['bank'] as String?,
    bankAccount: (json['bankAccount'] ?? json['bankaccount']) as String?,
    taxId: (json['taxId'] ?? json['taxid']) as String?,
    creditExactText: _clientRecordedNumber(json, 'credit'),
    credit: _clientLegacyNumber(json['credit']),
    creditDisplayText: json['creditDisplayText'] as String?,
    creditFloorDisplayText: json['creditFloorDisplayText'] as String?,
    creditFloorExactText: _clientRecordedNumber(json, 'creditFloor'),
    creditFloor: _clientLegacyNumber(json['creditFloor']) ?? 0,
    website: json['website'] as String?,
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    categoryId: json['categoryId'] as String?,
    ownerEmployeeId: json['ownerEmployeeId'] as String?,
    ownerEmployeeName: json['ownerEmployeeName'] as String?,
    ownerEmployeeIds:
        (json['ownerEmployeeIds'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const [],
    ownerEmployeeNames:
        (json['ownerEmployeeNames'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const [],
    defaultSettlementMethodId: json['defaultSettlementMethodId'] as String?,
    defaultSettlementMethodName: json['defaultSettlementMethodName'] as String?,
    defaultShipmentPolicy: json['defaultShipmentPolicy'] as String?,
    defaultCurrencyId: json['defaultCurrencyId'] as String?,
    defaultCurrencyName: json['defaultCurrencyName'] as String?,
    writable: json['writable'] as bool? ?? false,
    financialWritable: json['financialWritable'] as bool? ?? false,
    accessManageable: json['accessManageable'] as bool? ?? false,
    version: (json['version'] as num?)?.toInt(),
  );
}

class ClientAccessReason {
  const ClientAccessReason._();

  static const unassigned = 'UNASSIGNED';
  static const manageable = 'MANAGEABLE';
  static const shared = 'SHARED';
  static const ownerScopeReadOnly = 'OWNER_SCOPE_READ_ONLY';
  static const unknown = 'UNKNOWN';
}

/// 客户详情（列表字段 + 关键业务字段，够看即可）。
class ClientDetail {
  const ClientDetail({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.region,
    this.linkman,
    this.legacyId,
    this.categoryId,
    this.categoryName,
    this.fullName,
    this.nameEn,
    this.clientRank,
    this.placeId,
    this.empId,
    this.legalPerson,
    this.mobile,
    this.phone,
    this.phone2,
    this.fax,
    this.postcode,
    this.address,
    this.email,
    this.website,
    this.shipVia,
    this.shipAddress,
    this.bank,
    this.bankAccount,
    this.taxId,
    this.credit,
    this.creditExactText,
    this.initTotal,
    this.initTotalExactText,
    this.creditFloor,
    this.creditFloorExactText,
    this.tday,
    this.remark,
    this.version,
    this.ownerEmployeeId,
    this.ownerEmployeeName,
    this.ownerEmployeeIds = const [],
    this.ownerEmployeeNames = const [],
    this.defaultSettlementMethodId,
    this.defaultSettlementMethodName,
    this.defaultShipmentPolicy,
    this.defaultCurrencyId,
    this.defaultCurrencyName,
    this.writable = false,
    this.financialWritable = false,
    this.accessManageable = false,
    this.accessReason = ClientAccessReason.unknown,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final String? region;
  final String? linkman;
  final int? legacyId;
  final String? categoryId;
  final String? categoryName;
  final String? fullName; // 全称

  /// Company name in English or another foreign language (clients.name_en).
  final String? nameEn;
  final String? clientRank; // 等级
  final String? placeId; // 地区文本
  final String? empId; // 业务员
  final String? legalPerson; // 法人
  final String? mobile;
  final String? phone;
  final String? phone2;
  final String? fax;
  final String? postcode;
  final String? address;
  final String? email;
  final String? website;
  final String? shipVia; // 运输方式
  final String? shipAddress; // 收货地址
  final String? bank; // 开户行
  final String? bankAccount; // 银行账号
  final String? taxId; // 税号
  final double? credit; // 信用额度
  final String? creditExactText;
  final double? initTotal; // 期初应收
  final String? initTotalExactText;
  final double? creditFloor; // 铺底额
  final String? creditFloorExactText;
  final int? tday; // 结算天数
  final String? remark; // 备注
  final int? version;
  final String? ownerEmployeeId;
  final List<String> ownerEmployeeIds;
  final List<String> ownerEmployeeNames;
  String get ownersLabel => ownerEmployeeNames.isNotEmpty
      ? ownerEmployeeNames.join('、')
      : ownerEmployeeName ?? '未分配';
  final String? ownerEmployeeName;
  final String? defaultSettlementMethodId;
  final String? defaultSettlementMethodName;

  /// 默认销售条款（V592 单一事实源）：新建销售订货单预填；每次下单自动写回最新选择。
  final String? defaultShipmentPolicy;
  final String? defaultCurrencyId;
  final String? defaultCurrencyName;
  final bool financialWritable;
  final bool writable;
  final bool accessManageable;
  final String accessReason;

  String get accessReasonLabel {
    switch (accessReason) {
      case ClientAccessReason.unassigned:
        return accessManageable ? '待分配(可设置负责人)' : '待分配(只读)';
      case ClientAccessReason.manageable:
        return '可管理(具体操作仍按功能权限)';
      case ClientAccessReason.shared:
        return '单客户共享(只读)';
      case ClientAccessReason.ownerScopeReadOnly:
        return '负责人数据范围(只读)';
      default:
        if (ownerEmployeeId == null && accessManageable) {
          return '待分配(可设置负责人)';
        }
        if (writable) {
          return '对象范围可维护(具体操作仍按功能权限)';
        }
        return '只读(访问来源未标明)';
    }
  }

  String get readOnlyActionHint =>
      accessReason == ClientAccessReason.unassigned && accessManageable
      ? '请先设置负责人'
      : '仅可查看';

  factory ClientDetail.fromJson(Map<String, dynamic> json) => ClientDetail(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    status: json['status'] as String?,
    region: json['region'] as String?,
    linkman: json['linkman'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
    categoryId: json['categoryId'] as String?,
    categoryName: json['categoryName'] as String?,
    fullName: (json['fullName'] ?? json['fullname']) as String?,
    nameEn: json['nameEn'] as String?,
    clientRank: json['clientRank'] as String?,
    placeId: (json['placeId'] ?? json['placeid']) as String?,
    empId: (json['empId'] ?? json['empid']) as String?,
    legalPerson: (json['legalPerson'] ?? json['legalperson']) as String?,
    mobile: json['mobile'] as String?,
    phone: json['phone'] as String?,
    phone2: json['phone2'] as String?,
    fax: json['fax'] as String?,
    postcode: json['postcode'] as String?,
    address: json['address'] as String?,
    email: json['email'] as String?,
    website: json['website'] as String?,
    shipVia: json['shipVia'] as String?,
    shipAddress: json['shipAddress'] as String?,
    bank: json['bank'] as String?,
    bankAccount: (json['bankAccount'] ?? json['bankaccount']) as String?,
    taxId: (json['taxId'] ?? json['taxid']) as String?,
    creditExactText: _clientRecordedNumber(json, 'credit'),
    credit: _clientLegacyNumber(json['credit']),
    initTotalExactText: _clientRecordedNumber(json, 'initTotal'),
    initTotal: _clientLegacyNumber(json['initTotal']),
    creditFloorExactText: _clientRecordedNumber(json, 'creditFloor'),
    creditFloor: _clientLegacyNumber(json['creditFloor']) ?? 0,
    tday: (json['tday'] as num?)?.toInt(),
    remark: json['remark'] as String?,
    version: (json['version'] as num?)?.toInt(),
    ownerEmployeeId: json['ownerEmployeeId'] as String?,
    ownerEmployeeName: json['ownerEmployeeName'] as String?,
    ownerEmployeeIds:
        (json['ownerEmployeeIds'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const [],
    ownerEmployeeNames:
        (json['ownerEmployeeNames'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const [],
    defaultSettlementMethodId: json['defaultSettlementMethodId'] as String?,
    defaultSettlementMethodName: json['defaultSettlementMethodName'] as String?,
    defaultShipmentPolicy: json['defaultShipmentPolicy'] as String?,
    defaultCurrencyId: json['defaultCurrencyId'] as String?,
    defaultCurrencyName: json['defaultCurrencyName'] as String?,
    writable: json['writable'] as bool? ?? false,
    financialWritable: json['financialWritable'] as bool? ?? false,
    accessManageable: json['accessManageable'] as bool? ?? false,
    accessReason: json['accessReason'] as String? ?? ClientAccessReason.unknown,
  );
}

/// 字段 facet 结果：各筛选字段的可选值桶 + 各字段空值计数。
///
/// fields 以字段 key（与 query 参数名一致：code/name/fullName/clientXz/tday/region/
/// placeId/empId/legalPerson/linkman/mobile/phone/phone2/fax/postcode/address/bank/
/// bankAccount/taxId/credit/website）索引，便于 [MasterDataTableView] 通用查找。
class ClientFacets {
  const ClientFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = [
    'code',
    'name',
    'fullName',
    'clientXz',
    'tday',
    'region',
    'placeId',
    'empId',
    'legalPerson',
    'linkman',
    'mobile',
    'phone',
    'phone2',
    'fax',
    'postcode',
    'address',
    'bank',
    'bankAccount',
    'taxId',
    'credit',
    'creditFloor',
    'website',
  ];

  factory ClientFacets.fromJson(Map<String, dynamic> json) {
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
    return ClientFacets(fields: fields, nullCounts: nullCounts);
  }
}
