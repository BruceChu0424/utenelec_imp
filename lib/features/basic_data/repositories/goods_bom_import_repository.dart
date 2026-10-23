// 组装信息导入：使用「导出组件」的列，序号级联段(1/2/2.1)
// 表达层级——导出改完可直接导回。两段式「先检测后提交」（与货品导入同口径），
// 检测返回绑定文件与全部父件状态的版本指纹；提交锁定后复核，拒绝覆盖检测后的变更。
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/goods_import.dart'
    show GoodsImportError, GoodsImportReviewRow;

/// 检测报告：行数 / 逐行错误 / 提醒（不拦提交）/ 每层行数。
class BomImportReport {
  const BomImportReport({
    required this.totalRows,
    required this.errors,
    required this.warnings,
    required this.levelCounts,
    required this.readyToImport,
    this.stateFingerprint,
    this.reviewRows = const [],
    this.addedRows = 0,
    this.unchangedRows = 0,
    this.fillRows = 0,
    this.conflictRows = 0,
  });

  final int totalRows;
  final List<GoodsImportError> errors;
  final List<GoodsImportError> warnings;
  final List<int> levelCounts;

  /// 无错时可导入行数。
  final int readyToImport;
  final String? stateFingerprint;
  final List<GoodsImportReviewRow> reviewRows;
  final int addedRows;
  final int unchangedRows;
  final int fillRows;
  final int conflictRows;

  bool get hasErrors => errors.isNotEmpty;

  factory BomImportReport.fromJson(Map<String, dynamic> json) =>
      BomImportReport(
        totalRows: (json['totalRows'] as num?)?.toInt() ?? 0,
        errors: [
          for (final e in (json['errors'] as List? ?? const []))
            GoodsImportError.fromJson(e as Map<String, dynamic>),
        ],
        warnings: [
          for (final e in (json['warnings'] as List? ?? const []))
            GoodsImportError.fromJson(e as Map<String, dynamic>),
        ],
        levelCounts: [
          for (final n in (json['levelCounts'] as List? ?? const []))
            (n as num).toInt(),
        ],
        readyToImport: (json['readyToImport'] as num?)?.toInt() ?? 0,
        stateFingerprint: json['stateFingerprint'] as String?,
        reviewRows: [
          for (final row in json['reviewRows'] as List? ?? const [])
            GoodsImportReviewRow.fromJson(row as Map<String, dynamic>),
        ],
        addedRows: (json['addedRows'] as num?)?.toInt() ?? 0,
        unchangedRows: (json['unchangedRows'] as num?)?.toInt() ?? 0,
        fillRows: (json['fillRows'] as num?)?.toInt() ?? 0,
        conflictRows: (json['conflictRows'] as num?)?.toInt() ?? 0,
      );
}

/// 提交结果：写入的父货品数 / 新增行数 / 替换掉的行数 / 层数 / 写入后的提醒。
class BomImportResult {
  const BomImportResult({
    required this.targets,
    required this.added,
    required this.removed,
    required this.levels,
    this.warnings = const [],
    this.updatedCount = 0,
    this.filledCount = 0,
    this.ignoredCount = 0,
    this.unchangedCount = 0,
  });

  final int targets;
  final int added;
  final int removed;
  final int levels;

  /// 写入后的提醒 (不拦写入)，如整批领料的料的单个重量与货品资料单重相差 20% 以上。
  final List<String> warnings;
  final int updatedCount;
  final int filledCount;
  final int ignoredCount;
  final int unchangedCount;

  factory BomImportResult.fromJson(Map<String, dynamic> json) =>
      BomImportResult(
        targets: (json['targets'] as num?)?.toInt() ?? 0,
        added: (json['added'] as num?)?.toInt() ?? 0,
        removed: (json['removed'] as num?)?.toInt() ?? 0,
        levels: (json['levels'] as num?)?.toInt() ?? 1,
        warnings: [
          for (final w in (json['warnings'] as List?) ?? const [])
            if (w is String && w.trim().isNotEmpty) w.trim(),
        ],
        updatedCount: (json['updatedCount'] as num?)?.toInt() ?? 0,
        filledCount: (json['filledCount'] as num?)?.toInt() ?? 0,
        ignoredCount: (json['ignoredCount'] as num?)?.toInt() ?? 0,
        unchangedCount: (json['unchangedCount'] as num?)?.toInt() ?? 0,
      );
}

/// 默认合并核对；完整替换和追加保留为显式选择的既有操作。
enum BomImportMode { merge, replace, append }

abstract interface class GoodsBomImportRepository {
  Future<BomImportReport> detect(String goodsId, Uint8List bytes);
  Future<BomImportResult> commit(
    String goodsId,
    Uint8List bytes, {
    required BomImportMode mode,
    required String stateFingerprint,
    Set<String> replaceRowKeys = const {},
  });
}

class DioGoodsBomImportRepository implements GoodsBomImportRepository {
  DioGoodsBomImportRepository(this.api);
  final ApiClient api;

  @override
  Future<BomImportReport> detect(String goodsId, Uint8List bytes) async {
    final json = await api.postBytes(
      ApiEndpoints.goodsBomImportDetect(goodsId),
      bytes,
    );
    return BomImportReport.fromJson(json);
  }

  @override
  Future<BomImportResult> commit(
    String goodsId,
    Uint8List bytes, {
    required BomImportMode mode,
    required String stateFingerprint,
    Set<String> replaceRowKeys = const {},
  }) async {
    final json = mode == BomImportMode.merge
        ? await api.post(
            ApiEndpoints.goodsBomImportCommit(goodsId),
            body: {
              'file': base64Encode(bytes),
              'mode': 'MERGE',
              'stateFingerprint': stateFingerprint,
              'replaceRowKeys': replaceRowKeys.toList(),
            },
          )
        : await api.postBytes(
            ApiEndpoints.goodsBomImportCommit(goodsId),
            bytes,
            query: {
              'mode': mode.name.toUpperCase(),
              'stateFingerprint': stateFingerprint,
            },
          );
    return BomImportResult.fromJson(json);
  }
}

final goodsBomImportRepositoryProvider = Provider<GoodsBomImportRepository>(
  (ref) => DioGoodsBomImportRepository(ref.watch(apiClientProvider)),
);
