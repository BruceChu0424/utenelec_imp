// 货品批量导入模型（对应后端 importing 包 records）。

/// 导入检测/提交中的单条错误。
class GoodsImportError {
  const GoodsImportError({required this.rowNum, required this.column, required this.message});
  final int rowNum;
  final String column;
  final String message;

  factory GoodsImportError.fromJson(Map<String, dynamic> j) => GoodsImportError(
        rowNum: (j['rowNum'] as num?)?.toInt() ?? 0,
        column: (j['column'] as String?) ?? '',
        message: (j['message'] as String?) ?? '',
      );
}

/// 导入「检测」报告（只读）。
class GoodsImportReport {
  const GoodsImportReport({
    required this.totalRows,
    required this.dataRows,
    required this.errors,
    required this.willCreateCategories,
    required this.willCreateColors,
    required this.willCreateUnits,
    required this.readyToImport,
  });
  final int totalRows;
  final int dataRows;
  final List<GoodsImportError> errors;
  final List<String> willCreateCategories;
  final List<String> willCreateColors;
  final List<String> willCreateUnits;
  final int readyToImport;

  bool get hasErrors => errors.isNotEmpty;

  factory GoodsImportReport.fromJson(Map<String, dynamic> j) => GoodsImportReport(
        totalRows: (j['totalRows'] as num?)?.toInt() ?? 0,
        dataRows: (j['dataRows'] as num?)?.toInt() ?? 0,
        errors: ((j['errors'] as List?) ?? const [])
            .map((e) => GoodsImportError.fromJson(e as Map<String, dynamic>))
            .toList(),
        willCreateCategories:
            ((j['willCreateCategories'] as List?) ?? const []).cast<String>(),
        willCreateColors:
            ((j['willCreateColors'] as List?) ?? const []).cast<String>(),
        willCreateUnits:
            ((j['willCreateUnits'] as List?) ?? const []).cast<String>(),
        readyToImport: (j['readyToImport'] as num?)?.toInt() ?? 0,
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
  });
  final String batchId;
  final int importedCount;
  final int createdCategories;
  final int createdColors;
  final int createdUnits;
  final List<String> createdCategoryPaths;

  factory GoodsImportResult.fromJson(Map<String, dynamic> j) => GoodsImportResult(
        batchId: (j['batchId'] as String?) ?? '',
        importedCount: (j['importedCount'] as num?)?.toInt() ?? 0,
        createdCategories: (j['createdCategories'] as num?)?.toInt() ?? 0,
        createdColors: (j['createdColors'] as num?)?.toInt() ?? 0,
        createdUnits: (j['createdUnits'] as num?)?.toInt() ?? 0,
        createdCategoryPaths:
            ((j['createdCategoryPaths'] as List?) ?? const []).cast<String>(),
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

  factory GoodsImportBatchInfo.fromJson(Map<String, dynamic> j) => GoodsImportBatchInfo(
        id: (j['id'] as String?) ?? '',
        createdAt: j['createdAt'] == null
            ? null
            : DateTime.tryParse(j['createdAt'].toString()),
        filename: j['filename'] as String?,
        rowCount: (j['rowCount'] as num?)?.toInt() ?? 0,
      );
}
