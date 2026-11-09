import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';

import '../../support/complete_read_plan_batches.dart';

class _MaterialReadApi extends ApiClient {
  _MaterialReadApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  String? invalid;
  int rowCount = 101;
  Completer<void>? tail;

  List<({int page, int size})> get batches => [
    for (final query in queries)
      (page: query['page'] as int, size: query['size'] as int),
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add({...?query});
    final page = query!['page'] as int, size = query['size'] as int;
    if (page == 2 && tail != null) await tail!.future;
    final total = invalid == 'total-drift' && page == 2
        ? rowCount + 1
        : rowCount;
    return {
      'page': page,
      'size': size,
      'total': total,
      'totalPages': (rowCount + size - 1) ~/ size,
      'readScopeVersion': invalid == 'revision' ? 'revision-$page' : 'same',
      'items': [
        if (!(invalid == 'empty-intermediate' && page == 1))
          for (
            var row = (page - 1) * size;
            row < page * size && row < rowCount;
            row++
          )
            {
              'goodsId': 'material-1',
              'goodsName': '真实指定材料',
              'colorId': invalid == 'duplicate' && page == 2
                  ? 'color-0'
                  : 'color-$row',
              'unitName': 'kg',
              'costBasis': 'OWN',
              'defaultLeafWarehouseId': 'leaf-1',
              'warehouseAvailableQty': 12.75,
            },
      ],
    };
  }
}

void main() {
  test(
    'complete request-material query is frozen before a caller list mutates across an await',
    () async {
      final gate = Completer<void>();
      final api = _MaterialReadApi()
        ..rowCount = 201
        ..tail = gate;
      final repository = WorkshopMaterialRepository(api);
      final ids = ['material-1'];
      final pending = repository.completeRequestMaterialsForGoods(
        'workshop-1',
        goodsIds: ids,
        isCurrent: () => true,
      );
      for (var turn = 0; turn < 100 && api.queries.length < 2; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.queries, hasLength(2));
      ids
        ..clear()
        ..add('different-source');
      gate.complete();
      final result = await pending;
      expect(result, hasLength(201));
      // Every later ladder batch, including those requested after the caller
      // mutated its list, still carries the frozen source identity.
      expect(api.batches, completeReadPlanBatches(201));
      expect(
        api.queries.every((query) => query['goodsIds'] == 'material-1'),
        isTrue,
      );
    },
  );

  test(
    'request material capability completes101 exact source identities in bounded batches',
    () async {
      final api = _MaterialReadApi();
      final repository = WorkshopMaterialRepository(api);
      final result = await repository.completeRequestMaterialsForGoods(
        'workshop-1',
        goodsIds: ['material-1'],
        isCurrent: () => true,
      );
      expect(result, hasLength(101));
      expect(result.map((row) => row.key).toSet(), hasLength(101));
      expect(result.last.colorId, 'color-100');
      expect(
        result.every(
          (row) =>
              row.goodsId == 'material-1' &&
              row.costBasis == 'OWN' &&
              row.defaultLeafWarehouseId == 'leaf-1' &&
              row.warehouseAvailableQty == 12.75,
        ),
        isTrue,
      );
      expect(api.batches, completeReadPlanBatches(101));
      expect(
        api.queries.every(
          (query) =>
              query['workshopId'] == 'workshop-1' &&
              query['goodsIds'] == 'material-1',
        ),
        isTrue,
      );
    },
  );
  for (final invalid in [
    'duplicate',
    'empty-intermediate',
    'total-drift',
    'revision',
  ]) {
    test(
      'request material capability rejects $invalid instead of returning partial candidates',
      () async {
        final api = _MaterialReadApi()..invalid = invalid;
        final repository = WorkshopMaterialRepository(api);
        await expectLater(
          repository.completeRequestMaterialsForGoods(
            'workshop-1',
            goodsIds: ['material-1'],
            isCurrent: () => true,
          ),
          throwsA(isA<ApiException>()),
        );
        api.invalid = null;
        final rows = await repository.completeRequestMaterialsForGoods(
          'workshop-1',
          goodsIds: ['material-1'],
          isCurrent: () => true,
        );
        expect(rows, hasLength(101));
      },
    );
  }
  test(
    'retired material scope never publishes an accepted prefix or starts another batch',
    () async {
      final gate = Completer<void>();
      final api = _MaterialReadApi()..tail = gate;
      final repository = WorkshopMaterialRepository(api);
      var current = true;
      final pending = repository.completeRequestMaterialsForGoods(
        'workshop-1',
        goodsIds: ['material-1'],
        isCurrent: () => current,
      );
      for (var turn = 0; turn < 100 && api.queries.length < 2; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.queries, hasLength(2));
      current = false;
      gate.complete();
      await expectLater(pending, throwsA(isA<UiWorkCancelled>()));
      expect(api.queries, hasLength(2));
    },
  );
}
