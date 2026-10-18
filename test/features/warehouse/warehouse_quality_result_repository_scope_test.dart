import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';

void main() {
  test(
    'detail and every batch detail read carry the selected warehouse',
    () async {
      final api = _ScopeApi();
      final repository = WarehouseQualityResultRepository(
        api,
        scopeWarehouseId: 'warehouse-B',
      );
      await repository.detail('PURCHASE', 'single-receipt');
      await Future.wait([
        repository.detail('PURCHASE', 'batch-receipt-1'),
        repository.detail('SUBCONTRACT', 'batch-receipt-2'),
      ]);
      expect(api.queries, hasLength(3));
      expect(api.queries, everyElement({'scopeWarehouseId': 'warehouse-B'}));
      expect(api.paths.toSet(), hasLength(3));
    },
  );

  test(
    'default detail scope is resolved by the server without an all-scope override',
    () async {
      final api = _ScopeApi();
      await WarehouseQualityResultRepository(api).detail('PURCHASE', 'receipt');
      expect(api.queries.single, isEmpty);
    },
  );

  test(
    'raw browsing counts never become task badges when TASK facts are missing',
    () async {
      final api = _ScopeApi(
        response: {
          'WAITING_INSPECTION': 91,
          'ALL_PASSED': 82,
          'PARTIAL_PASSED': 73,
          'RETURN_REQUIRED': 64,
          'COMPLETED': 55,
        },
      );
      final counts = await WarehouseQualityResultRepository(api).statusCounts();
      for (final status in WarehouseQualityWorkStatus.values.where(
        (status) => !status.isCompleted,
      )) {
        expect(
          counts[status],
          0,
          reason: '${status.apiValue} has no task audience evidence',
        );
      }
      expect(counts[WarehouseQualityWorkStatus.completed], 55);
    },
  );

  test(
    'red and yellow counts use only TASK facts while completed remains browsing data',
    () async {
      final api = _ScopeApi(
        response: {
          'WAITING_INSPECTION': 91,
          'ALL_PASSED': 82,
          'PARTIAL_PASSED': 73,
          'RETURN_REQUIRED': 64,
          'COMPLETED': 55,
          'TASK_WAITING_INSPECTION': 1,
          'TASK_ALL_PASSED': 2,
          'TASK_PARTIAL_PASSED': 3,
          'TASK_RETURN_REQUIRED': 4,
          'TASK_COMPLETED': 999,
        },
      );
      final counts = await WarehouseQualityResultRepository(
        api,
      ).statusCounts(scopeWarehouseId: 'warehouse-B');
      expect(counts, {
        WarehouseQualityWorkStatus.waitingInspection: 1,
        WarehouseQualityWorkStatus.allPassed: 2,
        WarehouseQualityWorkStatus.partialPassed: 3,
        WarehouseQualityWorkStatus.returnRequired: 4,
        WarehouseQualityWorkStatus.completed: 55,
      });
      expect(api.queries.single['scopeWarehouseId'], 'warehouse-B');
    },
  );

  test(
    'revoked or absent TASK facts clear earlier red and yellow counts without raw fallback',
    () async {
      final api = _ScopeApi(
        response: {'TASK_WAITING_INSPECTION': 8, 'TASK_ALL_PASSED': 9},
      );
      final repository = WarehouseQualityResultRepository(api);
      final before = await repository.statusCounts();
      expect(before[WarehouseQualityWorkStatus.waitingInspection], 8);
      expect(before[WarehouseQualityWorkStatus.allPassed], 9);

      api.response = {
        'WAITING_INSPECTION': 100,
        'ALL_PASSED': 100,
        'PARTIAL_PASSED': 100,
        'RETURN_REQUIRED': 100,
        'TASK_WAITING_INSPECTION': 0,
        'TASK_ALL_PASSED': null,
      };
      final after = await repository.statusCounts();
      expect(after.values, everyElement(0));
    },
  );
}

class _ScopeApi extends ApiClient {
  _ScopeApi({this.response}) : super(Dio());

  Map<String, dynamic>? response;
  final paths = <String>[];
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    queries.add(Map<String, dynamic>.from(query ?? const {}));
    return response ??
        {
          'receiptType': path.contains('SUBCONTRACT')
              ? 'SUBCONTRACT'
              : 'PURCHASE',
          'receiptId': path.split('/').last,
          'workStatus': 'WAITING_INSPECTION',
        };
  }
}
