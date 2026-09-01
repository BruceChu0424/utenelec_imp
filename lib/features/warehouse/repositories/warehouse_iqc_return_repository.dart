import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/warehouse_iqc_return.dart';

/// IQC 实物退回写网关（合并页「品质部检查结果」接管列表与详情读路径后，
/// 只剩退回凭证登记）。
abstract interface class WarehouseIqcReturnGateway {
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

final warehouseIqcReturnRepositoryProvider =
    Provider<WarehouseIqcReturnGateway>((ref) {
      return WarehouseIqcReturnRepository(ref.watch(apiClientProvider));
    });
