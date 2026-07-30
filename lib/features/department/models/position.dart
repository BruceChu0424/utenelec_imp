// 岗位模型（对应后端 Position）。
// level 取值如 领导层/班组管理/员工；sortOrder 控制组内排序。

/// 岗位。
class Position {
  const Position({
    required this.id,
    required this.code,
    required this.name,
    required this.level,
    this.sortOrder,
  });

  final String id;
  final String code;
  final String name;
  final String level;
  final int? sortOrder;

  factory Position.fromJson(Map<String, dynamic> json) => Position(
    id: json['id'] as String,
    code: json['code'] as String? ?? '',
    name: json['name'] as String? ?? '',
    level: json['level'] as String? ?? '',
    sortOrder: (json['sortOrder'] as num?)?.toInt(),
  );
}

/// 新建岗位请求（POST /org/departments/{deptId}/positions）。
class PositionSaveInput {
  const PositionSaveInput({
    required this.code,
    required this.name,
    this.level,
    this.sortOrder,
  });

  final String code;
  final String name;
  final String? level;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    if (level != null) 'level': level,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}

/// 编辑岗位请求（PUT /org/positions/{id}）。
class PositionUpdateInput {
  const PositionUpdateInput({required this.name, this.level, this.sortOrder});

  final String name;
  final String? level;
  final int? sortOrder;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (level != null) 'level': level,
    if (sortOrder != null) 'sortOrder': sortOrder,
  };
}
