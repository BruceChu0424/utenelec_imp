// 供应商主档模型（对应后端 SupplierListItem / SupplierDetail / SupplierFacets）。
//
// 与 goods_node.dart 同构。ListItem 覆盖用户指定的 21 列展示字段中的 19 个有物理列的字段：
//   name/description/tday/place/empId/legalPerson/linkman/mobile/phone/phone2/
//   fax/postcode/address/bank/bankAccount/taxId/website/shipVia/shipAddress
// （编号 code 不在用户列表内；主结账方式/损耗率无对应物理列，不进 DTO。）
//
// 数值字段一律走 (json['x'] as num?)?.toInt()/toDouble()，避免 int/double 被后端
// 序列化成 String（或 null）时直接 cast 崩溃——老库迁移常踩这个坑。
// 连续大写/驼峰边界字段（legalPerson/bankAccount/taxId/empId/shipVia/shipAddress）后端
// 已 @JsonProperty 钉死；前端 fromJson 兼容大小写两种写法兜底。

import 'master_facet.dart';

/// 供应商列表项（覆盖表格 19 个有数据列 + id/legacyId）。
class SupplierListItem {
  const SupplierListItem({
    required this.id,
    this.legacyId,
    this.name,
    this.description,
    this.tday,
    this.place,
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
    this.website,
    this.shipVia,
    this.shipAddress,
  });

  final String id;
  final int? legacyId;

  // 用户指定的 21 列（19 个有数据列）
  final String? name; // 供应商简称（Vend_Name）
  final String? description; // 全称（Vend_Desc）
  final int? tday; // 信用天数（TDay，INT）
  final String? place; // 所属地区（Vend_Place）
  final String? empId; // 业务员（Emp_ID）
  final String? legalPerson; // 法人代表（Juri_Per）
  final String? linkman; // 联系人（Link_Man）
  final String? mobile; // 手机
  final String? phone; // 联系电话
  final String? phone2; // 备用电话
  final String? fax; // 传真
  final String? postcode; // 邮编
  final String? address; // 地址
  final String? bank; // 开户银行
  final String? bankAccount; // 银行账号
  final String? taxId; // 纳税号
  final String? website; // 网址
  final String? shipVia; // 运输方式
  final String? shipAddress; // 送货地址

  factory SupplierListItem.fromJson(Map<String, dynamic> json) => SupplierListItem(
        id: json['id'] as String,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        name: json['name'] as String?,
        description: json['description'] as String?,
        tday: (json['tday'] as num?)?.toInt(),
        place: json['place'] as String?,
        // 后端 @JsonProperty("empId") 输出 empId；兼容小写兜底。
        empId: (json['empId'] ?? json['empid']) as String?,
        // 后端 @JsonProperty("legalPerson") 输出 legalPerson；兼容小写兜底。
        legalPerson: (json['legalPerson'] ?? json['legalperson']) as String?,
        linkman: json['linkman'] as String?,
        mobile: json['mobile'] as String?,
        phone: json['phone'] as String?,
        phone2: (json['phone2'] ?? json['phone2']) as String?,
        fax: json['fax'] as String?,
        postcode: json['postcode'] as String?,
        address: json['address'] as String?,
        bank: json['bank'] as String?,
        bankAccount: (json['bankAccount'] ?? json['bankaccount']) as String?,
        taxId: (json['taxId'] ?? json['taxid']) as String?,
        website: json['website'] as String?,
        shipVia: (json['shipVia'] ?? json['shipvia']) as String?,
        shipAddress: (json['shipAddress'] ?? json['shipaddress']) as String?,
      );
}

/// 供应商详情（列表字段 + 关键业务字段，够看即可）。
class SupplierDetail {
  const SupplierDetail({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.place,
    this.linkman,
    this.legacyId,
    this.categoryId,
    this.categoryName,
    this.description,
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
    this.initTotal,
    this.tday,
    this.remark,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final String? place;
  final String? linkman;
  final int? legacyId;
  final String? categoryId;
  final String? categoryName;
  final String? description; // 描述/全称（Vend_Desc）
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
  final double? initTotal; // 期初应付
  final int? tday; // 结算天数
  final String? remark; // 备注

  factory SupplierDetail.fromJson(Map<String, dynamic> json) => SupplierDetail(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String?,
        place: json['place'] as String?,
        linkman: json['linkman'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        categoryId: json['categoryId'] as String?,
        categoryName: json['categoryName'] as String?,
        description: json['description'] as String?,
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
        shipVia: (json['shipVia'] ?? json['shipvia']) as String?,
        shipAddress: (json['shipAddress'] ?? json['shipaddress']) as String?,
        bank: json['bank'] as String?,
        bankAccount: (json['bankAccount'] ?? json['bankaccount']) as String?,
        taxId: (json['taxId'] ?? json['taxid']) as String?,
        initTotal: (json['initTotal'] as num?)?.toDouble(),
        tday: (json['tday'] as num?)?.toInt(),
        remark: json['remark'] as String?,
      );
}

/// 字段 facet 结果：各筛选字段的可选值桶 + 各字段空值计数。
///
/// fields 以字段 key（与 query 参数名一致：name/description/tday/place/empId/legalPerson/
/// linkman/mobile/phone/phone2/fax/postcode/address/bank/bankAccount/taxId/website/
/// shipVia/shipAddress）索引，便于 [MasterDataTableView] 通用查找。
/// 主结账方式（无对应列）与损耗率（无对应列）不在此处。
class SupplierFacets {
  const SupplierFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = [
    'name',
    'description',
    'tday',
    'place',
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
    'website',
    'shipVia',
    'shipAddress',
  ];

  factory SupplierFacets.fromJson(Map<String, dynamic> json) {
    final fields = <String, List<MasterFacetBucket>>{};
    for (final k in _keys) {
      final list = json[k];
      fields[k] = list is List
          ? list
              .map((e) =>
                  MasterFacetBucket.fromJson(e as Map<String, dynamic>))
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
    return SupplierFacets(fields: fields, nullCounts: nullCounts);
  }
}
