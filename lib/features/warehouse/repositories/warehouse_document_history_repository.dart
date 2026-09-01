import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/warehouse_document_history.dart';

abstract interface class WarehouseDocumentHistoryGateway {
  Future<PagedResult<WarehouseDocumentHistorySummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
  });

  Future<WarehouseDocumentHistoryDetail> detail(String id);
}

class WarehouseDocumentHistoryRepository
    implements WarehouseDocumentHistoryGateway {
  const WarehouseDocumentHistoryRepository(this.api, this.type);

  final ApiClient api;
  final WarehouseDocumentHistoryType type;

  String get _basePath => '/warehouse/document-history/${type.segment}';

  @override
  Future<PagedResult<WarehouseDocumentHistorySummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
  }) async {
    final safePage = page < 1 ? 1 : page;
    final safeSize = size.clamp(1, 100);
    final query = <String, dynamic>{'page': safePage, 'size': safeSize};
    final safeKeyword = _trimmed(keyword);
    final safeStatus = _trimmed(status);
    if (safeKeyword != null) {
      query['keyword'] = safeKeyword;
    }
    if (safeStatus != null) {
      query['status'] = safeStatus;
    }
    final json = await api.get(_basePath, query: query);
    return PagedResult<WarehouseDocumentHistorySummary>.fromJson(
      json,
      (item) => WarehouseDocumentHistorySummary.fromJson(type, item),
    );
  }

  @override
  Future<WarehouseDocumentHistoryDetail> detail(String id) async {
    final safeId = id.trim();
    if (safeId.isEmpty) throw const FormatException('仓库历史记录 id 不能为空');
    final json = await api.get('$_basePath/${Uri.encodeComponent(safeId)}');
    final body = json['data'] is Map
        ? Map<String, dynamic>.from(json['data'] as Map)
        : json;
    return WarehouseDocumentHistoryDetail.fromJson(type, body);
  }
}

String? _trimmed(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

final warehouseDocumentHistoryRepositoryProvider =
    Provider.family<
      WarehouseDocumentHistoryGateway,
      WarehouseDocumentHistoryType
    >((ref, type) {
      return WarehouseDocumentHistoryRepository(
        ref.watch(apiClientProvider),
        type,
      );
    });
