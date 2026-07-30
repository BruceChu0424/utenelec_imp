// 模具主档模型（对应后端 MouldListItem / MouldDetail / MouldFacets）。
//
// 与 goods_node 同构，字段换成模具相关。数值字段一律走
// (json['x'] as num?)?.toInt()/toDouble()，避免后端序列化成 String（或 null）
// 时直接 cast 崩溃——老库迁移常踩这个坑（见 MEMORY: Flutter fromJson int cast 坑）。
// tqty 为后端 BigDecimal（NUMERIC(18,4)），前端按 double 解析。

import 'master_facet.dart';

/// 模具列表项（表格中"有数据"的 6 列 + legacyId）。
///
/// 表格里另有 4 列（模数/套数/模具类型/制造商）在 V34 表无对应字段，由前端以 null
/// 取值显示"—"，不参与后端筛选/facet，故无对应模型字段。
class MouldListItem {
  const MouldListItem({
    required this.id,
    this.code,
    this.name,
    this.place,
    this.mstatus,
    this.status,
    this.remark,
    this.legacyId,
  });

  final String id;
  final String? code; // 模具编号（Number，如 C20-001【B3-12】）
  final String? name; // 模具名称（MouldName）
  final String? place; // 存放位置（车间/位置）
  final String? mstatus; // 制造日期（源 MStatus，制造年月如 2018年7月）
  final String? status; // 状态（生命周期：使用/禁用）
  final String? remark; // 备注
  final int? legacyId;

  factory MouldListItem.fromJson(Map<String, dynamic> json) => MouldListItem(
        id: json['id'] as String,
        code: json['code'] as String?,
        name: json['name'] as String?,
        place: json['place'] as String?,
        mstatus: json['mstatus'] as String?,
        status: json['status'] as String?,
        remark: json['remark'] as String?,
        legacyId: (json['legacyId'] as num?)?.toInt(),
      );
}

/// 模具详情（列表字段 + 关键业务字段，够看即看）。
///
/// 比 [MouldListItem] 多承载编辑弹窗/详情面板需要的全量业务字段（备用编号/数量/总数量/保管人/
/// 分类等），对应后端 MouldDetail。
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

/// 字段 facet 结果：各筛选字段的可选值桶 + 各字段空值计数。
///
/// fields 以字段 key（与 query 参数名一致：code/name/place/mstatus/remark/status）索引，
/// 便于 [MasterDataTableView] 通用查找。模数/套数/模具类型/制造商无 DB 列，不在此处。
class MouldFacets {
  const MouldFacets({required this.fields, required this.nullCounts});

  final Map<String, List<MasterFacetBucket>> fields;
  final Map<String, int> nullCounts;

  static const _keys = [
    'code',
    'name',
    'place',
    'mstatus',
    'remark',
    'status',
  ];

  factory MouldFacets.fromJson(Map<String, dynamic> json) {
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
    return MouldFacets(fields: fields, nullCounts: nullCounts);
  }
}
