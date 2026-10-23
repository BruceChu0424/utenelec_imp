// 货品批量导入模型（对应后端 importing 包 records）。

/// 导入检测/提交中的单条错误。
class GoodsImportError {
  const GoodsImportError({
    required this.rowNum,
    required this.column,
    required this.message,
  });
  final int rowNum;
  final String column;
  final String message;

  factory GoodsImportError.fromJson(Map<String, dynamic> j) => GoodsImportError(
    rowNum: (j['rowNum'] as num?)?.toInt() ?? 0,
    column: (j['column'] as String?) ?? '',
    message: (j['message'] as String?) ?? '',
  );
}

/// 文件中一个非空字段相对当前主档或 BOM 行的变化。
class GoodsImportChange {
  const GoodsImportChange({
    required this.field,
    required this.label,
    required this.oldValue,
    required this.newValue,
    required this.kind,
  });

  final String field;
  final String label;
  final String? oldValue;
  final String? newValue;
  final String kind;
  bool get isConflict => kind == 'CONFLICT';

  factory GoodsImportChange.fromJson(Map<String, dynamic> json) =>
      GoodsImportChange(
        field: json['field'] as String? ?? '',
        label: json['label'] as String? ?? '',
        oldValue: json['oldValue']?.toString(),
        newValue: json['newValue']?.toString(),
        kind: json['kind'] as String? ?? 'CONFLICT',
      );
}

/// 检测计划里的稳定行键。提交只传用户选中的冲突行键，不信任客户端字段值。
class GoodsImportReviewRow {
  const GoodsImportReviewRow({
    required this.rowKey,
    required this.rowNum,
    required this.code,
    required this.name,
    required this.categoryPath,
    required this.matchType,
    required this.changes,
    this.seq,
  });

  final String rowKey;
  final int rowNum;
  final String code;
  final String name;
  final String categoryPath;
  final String matchType;
  final String? seq;
  final List<GoodsImportChange> changes;
  bool get hasConflicts => changes.any((change) => change.isConflict);

  factory GoodsImportReviewRow.fromJson(Map<String, dynamic> json) =>
      GoodsImportReviewRow(
        rowKey: json['rowKey'] as String? ?? '',
        rowNum: (json['rowNum'] as num?)?.toInt() ?? 0,
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        categoryPath: json['categoryPath'] as String? ?? '',
        matchType: json['matchType'] as String? ?? '',
        seq: json['seq']?.toString(),
        changes: [
          for (final change in json['changes'] as List? ?? const [])
            GoodsImportChange.fromJson(change as Map<String, dynamic>),
        ],
      );
}

/// 导入「检测」报告(只读)。
class GoodsImportReport {
  const GoodsImportReport({
    required this.totalRows,
    required this.dataRows,
    required this.errors,
    required this.willCreateCategories,
    required this.willCreateColors,
    required this.willCreateUnits,
    required this.readyToImport,
    required this.restorableRows,
    required this.planId,
    this.reviewRows = const [],
    this.addedRows = 0,
    this.unchangedRows = 0,
    this.fillRows = 0,
    this.conflictRows = 0,
  });
  final int totalRows;
  final int dataRows;
  final List<GoodsImportError> errors;
  final List<String> willCreateCategories;
  final List<String> willCreateColors;
  final List<String> willCreateUnits;
  final int readyToImport;

  /// 将恢复的已删除货品行数（同编号命中软删行，导入时原 UUID 原编号复活）。
  final int restorableRows;

  /// 短期、单次使用的 detect -> commit 计划。服务重启或过期后须重新检测。
  final String? planId;
  final List<GoodsImportReviewRow> reviewRows;
  final int addedRows;
  final int unchangedRows;
  final int fillRows;
  final int conflictRows;

  bool get hasErrors => errors.isNotEmpty;

  factory GoodsImportReport.fromJson(Map<String, dynamic> j) =>
      GoodsImportReport(
        totalRows: (j['totalRows'] as num?)?.toInt() ?? 0,
        dataRows: (j['dataRows'] as num?)?.toInt() ?? 0,
        errors: ((j['errors'] as List?) ?? const [])
            .map((e) => GoodsImportError.fromJson(e as Map<String, dynamic>))
            .toList(),
        willCreateCategories: ((j['willCreateCategories'] as List?) ?? const [])
            .cast<String>(),
        willCreateColors: ((j['willCreateColors'] as List?) ?? const [])
            .cast<String>(),
        willCreateUnits: ((j['willCreateUnits'] as List?) ?? const [])
            .cast<String>(),
        readyToImport: (j['readyToImport'] as num?)?.toInt() ?? 0,
        restorableRows: (j['restorableRows'] as num?)?.toInt() ?? 0,
        planId: j['planId'] as String?,
        reviewRows: [
          for (final row in j['reviewRows'] as List? ?? const [])
            GoodsImportReviewRow.fromJson(row as Map<String, dynamic>),
        ],
        addedRows: (j['addedRows'] as num?)?.toInt() ?? 0,
        unchangedRows: (j['unchangedRows'] as num?)?.toInt() ?? 0,
        fillRows: (j['fillRows'] as num?)?.toInt() ?? 0,
        conflictRows: (j['conflictRows'] as num?)?.toInt() ?? 0,
      );
}

/// 导入「提交」结果。
class GoodsImportResult {
  const GoodsImportResult({
    required this.batchId,
    required this.importedCount,
    required this.createdCategories,
    required this.createdColors,
    required this.createdUnits,
    required this.createdCategoryPaths,
    this.createdCount = 0,
    this.updatedCount = 0,
    this.filledCount = 0,
    this.ignoredCount = 0,
    this.unchangedCount = 0,
    this.restoredCount = 0,
  });
  final String batchId;
  final int importedCount;
  final int createdCategories;
  final int createdColors;
  final int createdUnits;
  final List<String> createdCategoryPaths;
  final int createdCount;
  final int updatedCount;
  final int filledCount;
  final int ignoredCount;
  final int unchangedCount;
  final int restoredCount;

  factory GoodsImportResult.fromJson(Map<String, dynamic> j) =>
      GoodsImportResult(
        batchId: (j['batchId'] as String?) ?? '',
        importedCount: (j['importedCount'] as num?)?.toInt() ?? 0,
        createdCategories: (j['createdCategories'] as num?)?.toInt() ?? 0,
        createdColors: (j['createdColors'] as num?)?.toInt() ?? 0,
        createdUnits: (j['createdUnits'] as num?)?.toInt() ?? 0,
        createdCategoryPaths: ((j['createdCategoryPaths'] as List?) ?? const [])
            .cast<String>(),
        createdCount: (j['createdCount'] as num?)?.toInt() ?? 0,
        updatedCount: (j['updatedCount'] as num?)?.toInt() ?? 0,
        filledCount: (j['filledCount'] as num?)?.toInt() ?? 0,
        ignoredCount: (j['ignoredCount'] as num?)?.toInt() ?? 0,
        unchangedCount: (j['unchangedCount'] as num?)?.toInt() ?? 0,
        restoredCount: (j['restoredCount'] as num?)?.toInt() ?? 0,
      );
}

/// 最近未撤回的导入批次摘要（撤回按钮入口用）。
class GoodsImportBatchInfo {
  const GoodsImportBatchInfo({
    required this.id,
    required this.createdAt,
    required this.filename,
    required this.rowCount,
  });
  final String id;
  final DateTime? createdAt;
  final String? filename;
  final int rowCount;

  factory GoodsImportBatchInfo.fromJson(Map<String, dynamic> j) =>
      GoodsImportBatchInfo(
        id: (j['id'] as String?) ?? '',
        createdAt: j['createdAt'] == null
            ? null
            : DateTime.tryParse(j['createdAt'].toString()),
        filename: j['filename'] as String?,
        rowCount: (j['rowCount'] as num?)?.toInt() ?? 0,
      );
}
