// 客户主档模型（对应后端 ClientListItem / ClientDetail）。
//
// 与 mould_node/goods_node 同构，字段换成客户相关。数值字段一律走
// (json['x'] as num?)?.toInt()/toDouble()，避免后端序列化成 String（或 null）
// 时直接 cast 崩溃——老库迁移常踩这个坑（见 MEMORY: Flutter fromJson int cast 坑）。
// credit/initTotal 为后端 BigDecimal（NUMERIC(18,4)），前端按 double 解析。

/// 客户列表项（轻量摘要）。
class ClientListItem {
  const ClientListItem({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.region,
    this.linkman,
    this.legacyId,
  });

  final String id;
  final String? code; // 客户编号（Number，如 WM001 / 川0002）
  final String? name; // 客户名称（Client_Name）
  final String? status; // 生命周期：使用 / 禁用
  final String? region; // 区域（QYName，如 外贸/内销南区）
  final String? linkman; // 联系人（Link_Man）
  final int? legacyId;

  factory ClientListItem.fromJson(Map<String, dynamic> json) => ClientListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String?,
        region: json['region'] as String?,
        linkman: json['linkman'] as String?,
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
        fullName: json['fullName'] as String?,
        clientRank: json['clientRank'] as String?,
        placeId: json['placeId'] as String?,
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
        credit: (json['credit'] as num?)?.toDouble(),
        initTotal: (json['initTotal'] as num?)?.toDouble(),
        tday: (json['tday'] as num?)?.toInt(),
        remark: json['remark'] as String?,
      );
}
