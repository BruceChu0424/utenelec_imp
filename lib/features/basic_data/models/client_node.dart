// 客户主档模型（对应后端 ClientListItem / ClientDetail / ClientFacets）。
//
// 数值字段一律走 (json['x'] as num?)?.toInt()/toDouble()，避免 int/double 被后端
// 序列化成 String（或 null）时直接 cast 崩溃——老库迁移常踩这个坑。
// credit 为后端 BigDecimal（NUMERIC(18,4)），前端按 double 解析。
// tday 为 Integer（TDay 结算天数）。
//
// 后端对 fullName / clientXz / placeId / empId / legalPerson / bankAccount / taxId
// 显式 @JsonProperty 钉死 key；fromJson 仍兼容小写兜底，防 Jackson bean 命名歧义。

import 'master_facet.dart';

/// 客户列表项（覆盖表格 23 列中 21 个有 DB 列的字段）。
class ClientListItem {
  const ClientListItem({
    required this.id,
    this.code,
    this.name,
    this.fullName,
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
    this.website,
    this.status,
    this.legacyId,
  });

  final String id;
  final String? code; // 客户编码（Number）
  final String? name; // 客户简称（Client_Name）
  final String? fullName; // 客户全称（Full_Name）
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
  final String? website; // 网址（Http）
  final String? status; // 状态（使用/禁用，详情用，不进表格列）
  final int? legacyId;

  factory ClientListItem.fromJson(Map<String, dynamic> json) => ClientListItem(
    id: json['id'] as String,
    code: json['code'] as String?,
    name: json['name'] as String?,
    // 后端 @JsonProperty("fullName") 输出 fullName；兼容小写兜底。
    fullName: (json['fullName'] ?? json['fullname']) as String?,
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
    credit: (json['credit'] as num?)?.toDouble(),
    website: json['website'] as String?,
    status: json['status'] as String?,
    legacyId: (json['legacyId'] as num?)?.toInt(),
  );
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
    this.initTotal,
    this.creditFloor,
    this.tday,
    this.remark,
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
  final double? initTotal; // 期初应收
  final double? creditFloor; // 铺底额（V121）
  final int? tday; // 结算天数
  final String? remark; // 备注

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
    credit: (json['credit'] as num?)?.toDouble(),
    initTotal: (json['initTotal'] as num?)?.toDouble(),
    creditFloor: (json['creditFloor'] as num?)?.toDouble(),
    tday: (json['tday'] as num?)?.toInt(),
    remark: json['remark'] as String?,
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
