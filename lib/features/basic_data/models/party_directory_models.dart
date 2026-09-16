// 客户/供应商资料子表模型（V579 party_contact_methods / party_addresses /
// party_activity_records），客户端与供应商共用一套模型，partyType 区分。
//
// 连续大写边界（isPrimary → 后端输出 primary）与实体 Lombok getter 对齐：
// boolean isPrimary() 序列化为 "primary"；前端按 primary 读取。

/// 联系方式（手机/电话/传真/邮箱/网址/其它）。
class PartyContactMethod {
  const PartyContactMethod({
    required this.id,
    required this.kind,
    required this.value,
    this.primary = false,
    this.remark,
    this.createdAt,
  });

  final String id;
  final String kind;
  final String value;
  final bool primary;
  final String? remark;
  final String? createdAt;

  static const kindLabels = {
    'MOBILE': '手机',
    'PHONE': '电话',
    'FAX': '传真',
    'EMAIL': '邮箱',
    'WEBSITE': '网址',
    'OTHER': '其它',
  };

  String get kindLabel => kindLabels[kind] ?? kind;

  factory PartyContactMethod.fromJson(Map<String, dynamic> json) =>
      PartyContactMethod(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? 'OTHER',
        value: json['value'] as String? ?? '',
        primary: json['primary'] == true,
        remark: json['remark'] as String?,
        createdAt: json['createdAt'] as String?,
      );
}

/// 地址（收货/开票注册/其它）。
class PartyAddress {
  const PartyAddress({
    required this.id,
    required this.kind,
    required this.address,
    this.defaultAddress = false,
    this.remark,
    this.createdAt,
  });

  final String id;
  final String kind;
  final String address;
  final bool defaultAddress;
  final String? remark;
  final String? createdAt;

  static const kindLabels = {
    'SHIPPING': '收货地址',
    'BILLING': '开票/注册地址',
    'OTHER': '其它地址',
  };

  String get kindLabel => kindLabels[kind] ?? kind;

  factory PartyAddress.fromJson(Map<String, dynamic> json) => PartyAddress(
    id: json['id'] as String,
    kind: json['kind'] as String? ?? 'SHIPPING',
    address: json['address'] as String? ?? '',
    defaultAddress: json['default'] == true,
    remark: json['remark'] as String?,
    createdAt: json['createdAt'] as String?,
  );
}

/// 跟进/行为记录（跟进/投诉/违约扣分/奖励/其它）。
class PartyActivityRecord {
  const PartyActivityRecord({
    required this.id,
    required this.kind,
    required this.content,
    this.scoreDelta = 0,
    this.createdByName,
    this.createdAt,
  });

  final String id;
  final String kind;
  final String content;
  final int scoreDelta;
  final String? createdByName;
  final String? createdAt;

  static const kindLabels = {
    'FOLLOW_UP': '跟进',
    'COMPLAINT': '投诉',
    'PENALTY': '违约',
    'REWARD': '奖励',
    'OTHER': '其它',
  };

  String get kindLabel => kindLabels[kind] ?? kind;

  factory PartyActivityRecord.fromJson(Map<String, dynamic> json) =>
      PartyActivityRecord(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? 'OTHER',
        content: json['content'] as String? ?? '',
        scoreDelta: (json['scoreDelta'] as num?)?.toInt() ?? 0,
        createdByName: json['createdByName'] as String?,
        createdAt: json['createdAt'] as String?,
      );
}
