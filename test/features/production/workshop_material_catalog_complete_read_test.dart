import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/workshop_material_choice_repository.dart';

import '../../support/versioned_summary_test_response.dart';

class _Api extends ApiClient {
  _Api({this.products = 500, this.workshops = 2}) : super(Dio());
  final int products;
  final int workshops;
  final reads = <(String, Map<String, dynamic>)>[];
  final writes = <Object?>[];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add((path, Map.of(query ?? const {})));
    expect(query?['includeOptions'], isFalse);
    return [
      for (var i = 0; i < products; i++)
        {
          'workshopDepartmentId': 'workshop-${i % workshops}',
          'productGoodsId': 'product-$i',
          'productName': '原产品$i',
          'segmentIds': ['segment-$i'],
          'taskCount': 1,
          'choiceRequired': true,
          'prefill': [
            {'goodsId': 'material-0'},
          ],
          'prefillSource': 'LEGACY_MATERIAL_TEXT',
          'options': <Object?>[],
          'bomWeights': <Object?>[],
          'alsoOrderMaterialsAllowed': true,
        },
    ];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final q = Map<String, dynamic>.of(query ?? const {});
    reads.add((path, q));
    if (path.endsWith('/material-changes')) {
      expect(q['includeOptions'], isFalse);
      return {
        'workshopDepartmentId': 'workshop-actual',
        'productGoodsId': 'product-actual',
        'lockVersion': 7,
        'earliestEffectiveFrom': '2026-11-06',
        'options': <Object?>[],
        'rows': [
          {
            'id': 'source-row',
            'materialGoodsId': 'material-0',
            'materialName': '原料',
            'unitWeightGrams': 2.125,
          },
        ],
      };
    }
    expect(path, '/workshop-material/choices/material-options');
    expect(
      q.containsKey('productId'),
      isFalse,
      reason: 'a workshop catalog token is never borrowed from one product',
    );
    final ids = (q['workshopIds'] as String).split(',');
    expect(ids.length, lessThanOrEqualTo(50));
    return versionedSummaryTestResponse(
      [
        for (var i = 0; i < 1001; i++)
          {
            'goodsId': 'material-$i',
            'name': i == 1000 ? '末尾中文颗粒' : '颗粒$i',
            'code': 'M$i',
            'unitName': 'kg',
            'gramsConvertible': true,
          },
      ],
      q,
      revision: 'catalog-${ids.length}',
    );
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(body);
    return {};
  }
}

void main() {
  test(
    '500 actually selected products share one complete1001 catalog without repeated product HTTP',
    () async {
      final api = _Api();
      final rows = await WorkshopMaterialChoiceRepository(api).pending([
        for (var i = 0; i < 500; i++) 'segment-$i',
      ], isCurrent: () => true);
      expect(rows, hasLength(500));
      expect(rows.every((row) => row.options.length == 1001), isTrue);
      expect(rows.last.options.last.goodsName, '末尾中文颗粒');
      expect(rows.first.options, same(rows.last.options));
      expect(rows.first.prefill.single.goodsId, 'material-0');
      expect(rows.first.prefillSource, 'LEGACY_MATERIAL_TEXT');
      expect(rows.last.alsoOrderMaterialsAllowed, isTrue);
      final catalogReads = api.reads
          .where((read) => read.$1.endsWith('/material-options'))
          .toList();
      expect(catalogReads, hasLength(2));
      expect(
        catalogReads.first.$2.containsKey('readSnapshotRevision'),
        isFalse,
      );
      expect(catalogReads.last.$2['readSnapshotRevision'], 'catalog-2');
      expect(api.writes, isEmpty);
    },
  );

  test(
    'read chunks cover all51 workshops without treating read50 as a user selection cap',
    () async {
      final api = _Api(products: 51, workshops: 51);
      final rows = await WorkshopMaterialChoiceRepository(api).pending([
        for (var i = 0; i < 51; i++) 'segment-$i',
      ], isCurrent: () => true);
      expect(rows, hasLength(51));
      expect(rows.every((row) => row.options.length == 1001), isTrue);
      final firstBatches = api.reads
          .where(
            (read) =>
                read.$1.endsWith('/material-options') && read.$2['page'] == 1,
          )
          .toList();
      expect(firstBatches, hasLength(2));
      final covered = {
        for (final read in firstBatches)
          ...(read.$2['workshopIds'] as String).split(','),
      };
      expect(covered, hasLength(51));
      expect(covered, contains('workshop-50'));
      expect(api.writes, isEmpty);
    },
  );

  test(
    'segment detail keeps actual identity original rows and lock version while reading the complete catalog',
    () async {
      final api = _Api();
      final data = await WorkshopMaterialChoiceRepository(
        api,
      ).segmentMaterials('segment-original', isCurrent: () => true);
      expect(data.rows.single.id, 'source-row');
      expect(data.rows.single.unitWeightGrams, 2.125);
      expect(data.lockVersion, 7);
      expect(data.earliestEffectiveFrom, '2026-11-06');
      expect(data.options, hasLength(1001));
      expect(
        api.reads
            .where((r) => r.$1.endsWith('/material-options'))
            .every((r) => r.$2['workshopIds'] == 'workshop-actual'),
        isTrue,
      );
      expect(api.writes, isEmpty);
    },
  );
}
