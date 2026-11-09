import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_document_history_config.dart';
import 'package:uten_imp/features/warehouse/repositories/production_draw_task_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_document_history_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;

import '../../support/complete_read_plan_batches.dart';

class _PageApi extends ApiClient {
  _PageApi() : super(Dio());
  final sizes = <Object?>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    sizes.add(query?['size']);
    return {
      'items': const <Object>[],
      'page': query?['page'] ?? 1,
      'size': query?['size'],
      'total': 0,
      'totalPages': 0,
    };
  }
}

/// Warehouse task lists are read completely on the shared progressive plan
/// (fetchPageSized forwards each batch size). A client-side cap below the
/// server page maximum turned every (page, 200) batch into a (page, 100)
/// request for other rows, costing a re-read per complete read.
void main() {
  const plan = CompleteReadBatchPlan.progressive;
  final readers =
      <String, Future<void> Function(ApiClient api, int page, int size)>{
        'production draw tasks': (api, page, size) =>
            ProductionDrawTaskRepository(api).tasks(page: page, size: size),
        'sales outbound': (api, page, size) =>
            WarehouseSalesOutboundRepository(api).list(page: page, size: size),
        'quality results': (api, page, size) =>
            WarehouseQualityResultRepository(api).list(page: page, size: size),
        'document history': (api, page, size) =>
            WarehouseDocumentHistoryRepository(
              api,
              WarehouseDocumentHistoryType.subcontractMaterialReturn,
            ).list(page: page, size: size),
      };
  for (final reader in readers.entries) {
    test(
      '${reader.key} forwards every ladder batch and caps at the server page maximum',
      () async {
        final api = _PageApi();
        // Beyond the largest batch: 50, 50, 100, 200, 200.
        final ladder = completeReadPlanBatches(plan.maxBatchSize * 3);
        for (final batch in ladder) {
          await reader.value(api, batch.page, batch.size);
        }
        await reader.value(api, 1, plan.maxBatchSize + 1);
        expect(api.sizes, [
          for (final batch in ladder) batch.size,
          plan.maxBatchSize,
        ]);
      },
    );
  }
}
