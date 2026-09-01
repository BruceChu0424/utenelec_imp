// 仓库侧「待领任务」轻量读模型：履约工作台公开投影（/operations/workbench/
// warehouse）的仓库允许清单副本——只含数量/货品/仓库/日期/状态与领料单深链，
// 不复用 operations_workbench 模型（架构边界：warehouse 不依赖其它 feature）。

class WarehouseDrawTask {
  const WarehouseDrawTask({
    required this.taskId,
    required this.planNo,
    required this.warehouseName,
    required this.goodsCode,
    required this.goodsName,
    required this.spec,
    required this.colorName,
    required this.unitName,
    required this.openQty,
    required this.taskStatus,
    required this.needDate,
    required this.expectedDate,
    required this.exceptionCode,
    required this.actionDocId,
    required this.actionDocType,
  });

  final String taskId;
  final String planNo;
  final String warehouseName;
  final String goodsCode;
  final String goodsName;
  final String spec;
  final String colorName;
  final String unitName;
  final num openQty;
  final String taskStatus;
  final String? needDate;
  final String? expectedDate;
  final String? exceptionCode;
  final String? actionDocId;
  final String? actionDocType;

  /// 领料单深链：服务端投影 actionDocCanView=true 时才有（对象范围裁剪）。
  String? get drawDocPath {
    final id = actionDocId;
    if (id == null || id.isEmpty) return null;
    if (actionDocType?.trim().toUpperCase() != 'DRAW') return null;
    return '/warehouse/DRAW/$id';
  }

  String get goodsLabel => [
    goodsCode,
    goodsName,
    if (spec.isNotEmpty) spec,
    if (colorName.isNotEmpty) colorName,
  ].join(' ');

  String get quantityText {
    final text = openQty
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return unitName.isEmpty ? text : '$text $unitName';
  }

  String get dueDate => needDate ?? expectedDate ?? '—';

  /// 仓库视角状态文案（履约状态字典的仓库子集；未知码原样显示）。
  String get statusLabel => switch (taskStatus.toUpperCase()) {
    'READY_TO_PICK' => '待备料 / 待领取',
    'PARTIAL' => '部分领取',
    'DONE' || 'COMPLETED' => '已完成',
    'OPEN_ANY' => '待完成',
    'BLOCKED' => '已阻塞',
    _ => taskStatus,
  };

  /// 异常文案：仓库只关心正常/逾期/异常事实，完整异常字典在履约工作台。
  String get exceptionLabel => switch (exceptionCode?.toUpperCase()) {
    null || '' => '正常',
    'OVERDUE_ANY' => '全部逾期',
    'OVERDUE' => '已逾期',
    _ => exceptionCode!,
  };

  factory WarehouseDrawTask.fromJson(Map<String, dynamic> json) {
    return WarehouseDrawTask(
      taskId: (json['taskId'] ?? '') as String,
      planNo: (json['planNo'] ?? '—') as String,
      warehouseName: (json['warehouseName'] ?? '') as String,
      goodsCode: (json['goodsCode'] ?? '') as String,
      goodsName: (json['goodsName'] ?? '') as String,
      spec: (json['spec'] ?? '') as String,
      colorName: (json['colorName'] ?? '') as String,
      unitName: (json['unitName'] ?? '') as String,
      openQty: (json['openQty'] as num?) ?? 0,
      taskStatus: (json['taskStatus'] ?? '') as String,
      needDate: json['needDate'] as String?,
      expectedDate: json['expectedDate'] as String?,
      exceptionCode: json['exceptionCode'] as String?,
      actionDocId: json['actionDocId'] as String?,
      actionDocType: json['actionDocType'] as String?,
    );
  }
}
