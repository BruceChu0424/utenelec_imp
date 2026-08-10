// 货品批量导入仓库（detect 只读 / commit 原子导入 / latest 最近批次 / undo 撤回）。
// 上传走原始字节流（postBytes，octet-stream），与附件直传同模式，不经 multipart。
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/goods_import.dart';

abstract interface class GoodsImportRepository {
  Future<GoodsImportReport> detect(Uint8List bytes);
  Future<GoodsImportResult> commit(Uint8List bytes, {String? filename});
  Future<GoodsImportBatchInfo?> latest();
  Future<void> undo(String batchId);
}

class DioGoodsImportRepository implements GoodsImportRepository {
  DioGoodsImportRepository(this.api);
  final ApiClient api;

  @override
  Future<GoodsImportReport> detect(Uint8List bytes) async {
    final json = await api.postBytes(ApiEndpoints.goodsImportDetect, bytes);
    return GoodsImportReport.fromJson(json);
  }

  @override
  Future<GoodsImportResult> commit(Uint8List bytes, {String? filename}) async {
    final json = await api.postBytes(
      ApiEndpoints.goodsImportCommit,
      bytes,
      query: (filename == null || filename.isEmpty) ? null : {'filename': filename},
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
