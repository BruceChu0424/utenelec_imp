// 组装信息导入：格式 = 「导出组件」的 14 列，序号级联段（1/2/2.1）
// 表达层级——导出改完可直接导回。两段式「先检测后提交」（与货品导入同口径），
// 检测返回绑定文件与全部父件状态的版本指纹；提交锁定后复核，拒绝覆盖检测后的变更。
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/goods_import.dart' show GoodsImportError;

/// 检测报告：行数 / 逐行错误 / 提醒（不拦提交）/ 每层行数。
class BomImportReport {
  const BomImportReport({
    required this.totalRows,
    required this.errors,
    required this.warnings,
    required this.levelCounts,
    required this.readyToImport,
    this.stateFingerprint,
  });

  final int totalRows;
  final List<GoodsImportError> errors;
  final List<GoodsImportError> warnings;
  final List<int> levelCounts;

  /// 无错时可导入行数。
  final int readyToImport;
  final String? stateFingerprint;

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
  });

  final int targets;
  final int added;
  final int removed;
  final int levels;

  /// 写入后的提醒 (不拦写入)，如整批领料的料的单个重量与货品资料单重相差 20% 以上。
  final List<String> warnings;

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
      );
}

/// 导入方式：按文件为准替换各级现有组件 / 在现有组件后追加（与粘贴组件同语义）。
enum BomImportMode { replace, append }

abstract interface class GoodsBomImportRepository {
  Future<BomImportReport> detect(String goodsId, Uint8List bytes);
  Future<BomImportResult> commit(
    String goodsId,
    Uint8List bytes, {
    required BomImportMode mode,
    required String stateFingerprint,
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
  }) async {
    final json = await api.postBytes(
      ApiEndpoints.goodsBomImportCommit(goodsId),
      bytes,
      query: {
        'mode': mode == BomImportMode.replace ? 'REPLACE' : 'APPEND',
        'stateFingerprint': stateFingerprint,
      },
    );
    return BomImportResult.fromJson(json);
  }
}

final goodsBomImportRepositoryProvider = Provider<GoodsBomImportRepository>(
  (ref) => DioGoodsBomImportRepository(ref.watch(apiClientProvider)),
);
