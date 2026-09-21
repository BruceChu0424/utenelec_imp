// ADR-098 委外回厂短交判定页 + 供应商损耗汇总的数据访问。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/subcontract_short_delivery.dart';
import '../../../shared/repositories/subcontract_loss_summary_loader.dart';

class SubcontractShortDeliveryRepository {
  SubcontractShortDeliveryRepository(this.api);

  final ApiClient api;

  static const String base = '/subcontract/short-deliveries';

  /// [segment]：PENDING（待判定，含分批等待逾期）/ WAITING（分批等待中）/ HISTORY。
  Future<PagedResult<SubcontractShortDeliveryCase>> list({
    String segment = 'PENDING',
    String? keyword,
    String? supplierId,
    String? orderId,
    String? dateFrom,
    String? dateTo,
    int page = 1,
    int size = 50,
  }) async {
    final json = await api.get(
      base,
      query: {
        'segment': segment,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (supplierId != null && supplierId.isNotEmpty)
          'supplierId': supplierId,
        if (orderId != null && orderId.isNotEmpty) 'orderId': orderId,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, SubcontractShortDeliveryCase.fromJson);
  }

  Future<SubcontractShortDeliveryCounts> counts() async {
    final json = await api.get('$base/count');
    return SubcontractShortDeliveryCounts.fromJson(json);
  }

  Future<SubcontractShortDeliveryDetail> detail(String id) async {
    final json = await api.get('$base/$id');
    return SubcontractShortDeliveryDetail.fromJson(json);
  }

  /// [decision]：WAIT_MORE（必填 [expectedCompleteBy] yyyy-MM-dd）/ ACCEPT_LOSS。
  Future<SubcontractShortDeliveryDetail> decide(
    String id, {
    required String decision,
    required int expectedVersion,
    String? expectedCompleteBy,
    String? note,
  }) async {
    final json = await api.post(
      '$base/$id/decide',
      body: {
        'decision': decision,
        'expectedVersion': expectedVersion,
        'expectedCompleteBy': ?expectedCompleteBy,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    );
    return SubcontractShortDeliveryDetail.fromJson(json);
  }

  Future<SubcontractSupplierLossSummary> supplierSummary(
    String supplierId,
  ) async {
    return loadSubcontractSupplierLossSummary(api, supplierId);
  }
}

final subcontractShortDeliveryRepositoryProvider =
    Provider<SubcontractShortDeliveryRepository>(
      (ref) => SubcontractShortDeliveryRepository(ref.watch(apiClientProvider)),
    );
