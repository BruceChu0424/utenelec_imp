// 模具主档模型（对应后端 MouldListItem / MouldDetail）。
//
// 与 goods_node 同构，字段换成模具相关。数值字段一律走
// (json['x'] as num?)?.toInt()/toDouble()，避免后端序列化成 String（或 null）
// 时直接 cast 崩溃——老库迁移常踩这个坑（见 MEMORY: Flutter fromJson int cast 坑）。
// tqty 为后端 BigDecimal（NUMERIC(18,4)），前端按 double 解析。

/// 模具列表项（轻量摘要）。
class MouldListItem {
  const MouldListItem({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.place,
    this.keeper,
    this.legacyId,
  });

  final String id;
  final String? code; // 模具编号（Number，如 C20-001【B3-12】）
  final String? name; // 模具名称（MouldName）
  final String? status; // 生命周期：使用 / 禁用
  final String? place; // 车间/位置
  final String? keeper; // 保管人
  final int? legacyId;

  factory MouldListItem.fromJson(Map<String, dynamic> json) => MouldListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String?,
        place: json['place'] as String?,
        keeper: json['keeper'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

/// 模具详情（列表字段 + 关键业务字段，够看即可）。
class MouldDetail {
  const MouldDetail({
    required this.id,
    this.code,
    this.name,
    this.status,
    this.place,
    this.keeper,
    this.legacyId,
    this.categoryId,
    this.categoryName,
    this.mnumber,
    this.qty,
    this.tqty,
    this.mstatus,
    this.remark,
  });

  final String id;
  final String? code;
  final String? name;
  final String? status;
  final String? place;
  final String? keeper;
  final int? legacyId;
  final String? categoryId;
  final String? categoryName;
  final String? mnumber; // 备用编号
  final String? qty; // 数量（如 1+1）
  final double? tqty; // 总数量
  final String? mstatus; // 制造年月（如 2018年7月）
  final String? remark; // 备注

  factory MouldDetail.fromJson(Map<String, dynamic> json) => MouldDetail(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String?,
        place: json['place'] as String?,
        keeper: json['keeper'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
        categoryId: json['categoryId'] as String?,
        categoryName: json['categoryName'] as String?,
        mnumber: json['mnumber'] as String?,
        qty: json['qty'] as String?,
        tqty: (json['tqty'] as num?)?.toDouble(),
        mstatus: json['mstatus'] as String?,
        remark: json['remark'] as String?,
      );
}
