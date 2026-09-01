import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/warehouse_iqc_return.dart';

abstract interface class WarehouseIqcReturnGateway {
  Future<PagedResult<WarehouseIqcReturnTask>> list({
    int page = 1,
    int size = 20,
    WarehouseIqcReceiptType? receiptType,
    String? physicalStatus,
    String? keyword,
  });

  Future<WarehouseIqcReturnTask> detail(String id);

  Future<WarehouseIqcReturnTask> recordReturn(
    String id,
    WarehouseIqcRecordReturnCommand command,
  );
}

class WarehouseIqcReturnRepository implements WarehouseIqcReturnGateway {
  const WarehouseIqcReturnRepository(this.api);

  static const _base = '/warehouse/iqc-returns';
  final ApiClient api;

  @override
  Future<PagedResult<WarehouseIqcReturnTask>> list({
    int page = 1,
    int size = 20,
    WarehouseIqcReceiptType? receiptType,
    String? physicalStatus,
    String? keyword,
  }) async {
    final query = <String, dynamic>{
      'page': page < 1 ? 1 : page,
      'size': size.clamp(1, 100),
      if (receiptType != null) 'receiptType': receiptType.apiValue,
    };
    if (_trimmed(physicalStatus) case final value?) {
      query['physicalStatus'] = value;
    }
    if (_trimmed(keyword) case final value?) query['keyword'] = value;
    final json = await api.get(_base, query: query);
    return PagedResult.fromJson(json, WarehouseIqcReturnTask.fromJson);
  }

  @override
  Future<WarehouseIqcReturnTask> detail(String id) async {
    final json = await api.get('$_base/${Uri.encodeComponent(_id(id))}');
    return WarehouseIqcReturnTask.fromJson(_body(json));
  }

  @override
  Future<WarehouseIqcReturnTask> recordReturn(
    String id,
    WarehouseIqcRecordReturnCommand command,
  ) async {
    final json = await api.post(
      '$_base/${Uri.encodeComponent(_id(id))}/record-return',
      body: command.toJson(),
    );
    return WarehouseIqcReturnTask.fromJson(_body(json));
  }
}

Map<String, dynamic> _body(Map<String, dynamic> json) {
  return json['data'] is Map
      ? Map<String, dynamic>.from(json['data'] as Map)
      : json;
}

String _id(String value) {
  final id = value.trim();
  if (id.isEmpty) throw const FormatException('IQC 实物退回任务 id 不能为空');
  return id;
}

String? _trimmed(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

final warehouseIqcReturnRepositoryProvider =
    Provider<WarehouseIqcReturnGateway>((ref) {
      return WarehouseIqcReturnRepository(ref.watch(apiClientProvider));
    });
