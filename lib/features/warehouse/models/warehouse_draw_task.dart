// 仓库侧「待领任务」轻量读模型：履约工作台公开投影（/operations/workbench/
// warehouse）的仓库允许清单副本——一行=一张 DRAW 领料单（按单据归组口径，
// 与 ADR-065 修订后的采购/委外一致），只含数量/货品/仓库/日期/状态与领料单
// 深链，不复用 operations_workbench 模型（架构边界：warehouse 不依赖其它 feature）。

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
    this.actionDocNo = '',
    this.actionDocStatus,
    this.goodsCount = 0,
    this.openLineCount = 0,
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
  final String actionDocNo;

  /// 领料单状态（服务端投影 action_doc_status：'0' 草稿 / '1' 已审 / '-1' 红冲）。
  final String? actionDocStatus;
  final int goodsCount;
  final int openLineCount;

  /// 归组行（一张领料单多行物料）：货品身份列改显示规模摘要。
  bool get isDocumentGrouped => goodsCount > 1 || openLineCount > 1;

  /// 草稿领料单：批量出库时走「出库即审核」，需要同时具备审核权限。
  bool get isDraftDoc => actionDocStatus?.trim() == '0';

  /// 本行可批量出库：挂有可见的 DRAW 领料单且尚未领完。
  bool get canBatchIssue =>
      drawDocPath != null && taskStatus.toUpperCase() != 'DONE';

  /// 领料单深链：服务端投影 actionDocCanView=true 时才有（对象范围裁剪）。
  String? get drawDocPath {
    final id = actionDocId;
    if (id == null || id.isEmpty) return null;
    if (actionDocType?.trim().toUpperCase() != 'DRAW') return null;
    return '/warehouse/DRAW/$id';
  }

  /// 单货品单据显示完整货品身份；多货品归组行显示「N 种物料 · N 行待领」。
  String get goodsLabel => isDocumentGrouped
      ? '$goodsCount 种物料${openLineCount > 0 ? ' · $openLineCount 行待领' : ''}'
      : [
          goodsCode,
          goodsName,
          if (spec.isNotEmpty) spec,
          if (colorName.isNotEmpty) colorName,
        ].join(' ');

  String get drawBillLabel => actionDocNo.isEmpty ? '—' : actionDocNo;

  String get quantityText {
    if (isDocumentGrouped) {
      return openLineCount > 0 ? '$openLineCount 行' : '—';
    }
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
      actionDocNo: (json['actionDocNo'] ?? '') as String,
      actionDocStatus: json['actionDocStatus']?.toString(),
      goodsCount: (json['goodsCount'] as num?)?.toInt() ?? 0,
      openLineCount: (json['openLineCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 批量出库结果（POST /stock/docs/issue-batch，对应后端 StockDocIssueBatchResponse）。
class WarehouseDrawBatchIssueResult {
  const WarehouseDrawBatchIssueResult({
    required this.issuedCount,
    required this.skippedCount,
    required this.replayedCount,
    required this.replayed,
    required this.issuedDocNos,
  });

  /// 本次新出库张数。
  final int issuedCount;

  /// 提交前已出完、不属于本批幂等键的单（自动跳过）。
  final int skippedCount;

  /// 已在本批（同操作人同幂等键）此前完成、按子幂等键识别为重放的单。
  final int replayedCount;

  /// 本批此前已全部完成：没有新增出库且至少一张按本批子键重放。
  final bool replayed;
  final List<String> issuedDocNos;

  factory WarehouseDrawBatchIssueResult.fromJson(Map<String, dynamic> json) =>
      WarehouseDrawBatchIssueResult(
        issuedCount: (json['issuedCount'] as num?)?.toInt() ?? 0,
        skippedCount: (json['skippedCount'] as num?)?.toInt() ?? 0,
        replayedCount: (json['replayedCount'] as num?)?.toInt() ?? 0,
        replayed: json['replayed'] == true,
        issuedDocNos: (json['issuedDocNos'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}
