// 货品批量导入仓库（detect 只读 / commit 原子导入 / latest 最近批次 / undo 撤回）。
// 检测上传原始字节；核对提交把文件与选择放在受限 JSON 请求体，避免大量选择超过 URL 限额。
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/goods_import.dart';

abstract interface class GoodsImportRepository {
  Future<GoodsImportReport> detect(
    Uint8List bytes, {
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
  });
  Future<GoodsImportResult> commit(
    Uint8List bytes, {
    required String planId,
    String? filename,
    Set<String> replaceRowKeys = const {},
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
  });
  Future<GoodsImportBatchInfo?> latest();
  Future<void> undo(String batchId);
}

class DioGoodsImportRepository implements GoodsImportRepository {
  DioGoodsImportRepository(this.api);
  final ApiClient api;

  @override
  Future<GoodsImportReport> detect(
    Uint8List bytes, {
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
  }) async {
    final json =
        codeCorrections.isEmpty &&
            cellCorrections.isEmpty &&
            excludedRowNums.isEmpty
        ? await api.postBytes(ApiEndpoints.goodsImportDetect, bytes)
        : await api.post(
            ApiEndpoints.goodsImportDetect,
            body: {
              'file': base64Encode(bytes),
              'codeCorrections': {
                for (final entry in codeCorrections.entries)
                  '${entry.key}': entry.value,
              },
              'excludedRowNums': excludedRowNums.toList(),
              if (cellCorrections.isNotEmpty)
                'cellCorrections': {
                  for (final entry in cellCorrections.entries)
                    '${entry.key}': entry.value,
                },
            },
          );
    return GoodsImportReport.fromJson(json);
  }

  @override
  Future<GoodsImportResult> commit(
    Uint8List bytes, {
    required String planId,
    String? filename,
    Set<String> replaceRowKeys = const {},
    Map<int, String> codeCorrections = const {},
    GoodsImportCorrections cellCorrections = const {},
    Set<int> excludedRowNums = const {},
  }) async {
    final normalizedPlanId = planId.trim();
    if (normalizedPlanId.isEmpty) {
      throw ArgumentError.value(planId, 'planId', '检测计划不能为空');
    }
    final json = await api.post(
      ApiEndpoints.goodsImportCommit,
      body: {
        'file': base64Encode(bytes),
        'planId': normalizedPlanId,
        if (filename != null && filename.isNotEmpty) 'filename': filename,
        'replaceRowKeys': replaceRowKeys.toList(),
        if (codeCorrections.isNotEmpty)
          'codeCorrections': {
            for (final entry in codeCorrections.entries)
              '${entry.key}': entry.value,
          },
        if (excludedRowNums.isNotEmpty)
          'excludedRowNums': excludedRowNums.toList(),
        if (cellCorrections.isNotEmpty)
          'cellCorrections': {
            for (final entry in cellCorrections.entries)
              '${entry.key}': entry.value,
          },
      },
    );
    return GoodsImportResult.fromJson(json);
  }

  @override
  Future<GoodsImportBatchInfo?> latest() async {
    final json = await api.get(ApiEndpoints.goodsImportLatest);
    if (json.isEmpty) return null;
    return GoodsImportBatchInfo.fromJson(json);
  }

  @override
  Future<void> undo(String batchId) async {
    await api.delete(ApiEndpoints.goodsImportUndo(batchId));
  }
}

final goodsImportRepositoryProvider = Provider<GoodsImportRepository>(
  (ref) => DioGoodsImportRepository(ref.watch(apiClientProvider)),
);
