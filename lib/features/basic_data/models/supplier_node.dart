// 供应商主档模型（对应后端 SupplierListItem / SupplierDetail）。
//
// 与 mould_node/client_node 同构，字段换成供应商相关。数值字段一律走
// (json['x'] as num?)?.toInt()/toDouble()，避免后端序列化坑（见 MEMORY: Flutter fromJson int cast 坑）。
// initTotal 为后端 BigDecimal（NUMERIC(18,4)），前端按 double 解析。

/// 供应商列表项（轻量摘要）。
class SupplierListItem {
  const SupplierListItem({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.place,
    this.linkman,
    this.legacyId,
  });

  final String id;
  final String? code; // 编号（Number，如 WJ0001 / SL0003）
  final String? name; // 供应商名称（Vend_Name，如 洪武）
  final String? status; // 生命周期：使用 / 禁用
  final String? place; // 地区（Vend_Place）
  final String? linkman; // 联系人（Link_Man）
  final int? legacyId;

  factory SupplierListItem.fromJson(Map<String, dynamic> json) =>
      SupplierListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String?,
        place: json['place'] as String?,
        linkman: json['linkman'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
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
        empId: json['empId'] as String?,
        legalPerson: json['legalPerson'] as String?,
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
        bankAccount: json['bankAccount'] as String?,
        taxId: json['taxId'] as String?,
        initTotal: (json['initTotal'] as num?)?.toDouble(),
        tday: (json['tday'] as num?)?.toInt(),
        remark: json['remark'] as String?,
      );
}
