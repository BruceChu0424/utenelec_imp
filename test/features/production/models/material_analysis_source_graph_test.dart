import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/material_analysis_source_graph.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

ProductionMaterialAnalysisMaterial row(
  String id, {
  List<String> targets = const [],
  String? action,
  String status = 'REQUESTED',
  double ordered = 0,
}) => ProductionMaterialAnalysisMaterial.fromJson({
  'materialLineId': id,
  'goodsId': 'same-goods',
  'aggregatePreparation': {
    'orderedQty': ordered,
    'targetMaterialLineIds': targets,
    'actionable': true,
  },
  'downstreamReferences': [
    if (action != null) {'actionId': action, 'status': status, 'route': 'MAKE'},
  ],
});

void main() {
  test(
    'resolves multiple generations and diamond links once by exact UUID',
    () {
      final graph = MaterialAnalysisSourceGraph([
        row('source-a', targets: ['middle', 'canonical']),
        row('source-b', targets: ['canonical']),
        row('middle', targets: ['canonical']),
        row('canonical', targets: ['canonical'], action: 'actual'),
        row('unrelated', action: 'same-goods-is-not-a-link'),
      ]);
      final result = graph.resolve(['source-a', 'source-b', 'source-a']);
      expect(result.complete, isTrue);
      expect(result.materials.map((row) => row.materialLineId).toSet(), {
        'source-a',
        'source-b',
        'middle',
        'canonical',
      });
      expect(result.activeActionIds, {'actual'});
      expect(result.hasIssuedSupply, isTrue);
      expect(graph.resolve(['unrelated']).activeActionIds, {
        'same-goods-is-not-a-link',
      });
    },
  );

  test('missing target fails closed without searching matching goods', () {
    final result = MaterialAnalysisSourceGraph([
      row('source', targets: ['missing']),
      row('unrelated', action: 'incorrect'),
    ]).resolve(['source']);
    expect(result.complete, isFalse);
    expect(result.activeActionIds, isEmpty);
  });

  test(
    'cycle terminates and marks incomplete while a self target is valid',
    () {
      final graph = MaterialAnalysisSourceGraph([
        row('a', targets: ['b']),
        row('b', targets: ['a']),
        row('self', targets: ['self']),
      ]);
      expect(graph.resolve(['a']).complete, isFalse);
      expect(graph.resolve(['self']).complete, isTrue);
    },
  );

  test(
    'cancelled references unlock; completed active supply still locks route',
    () {
      final graph = MaterialAnalysisSourceGraph([
        row('cancelled', action: 'old', status: 'CANCELLED'),
        row('done', action: 'done', status: 'DONE'),
        row('minimum-issued', ordered: 0.0001),
      ]);
      expect(graph.resolve(['cancelled']).hasIssuedSupply, isFalse);
      expect(graph.resolve(['cancelled']).activeActionIds, isEmpty);
      expect(graph.resolve(['done']).hasIssuedSupply, isTrue);
      expect(graph.resolve(['minimum-issued']).hasIssuedSupply, isTrue);
    },
  );

  test(
    'snapshot graph never carries prior supply state into a new snapshot',
    () {
      final old = MaterialAnalysisSourceGraph([row('a', action: 'old')]);
      expect(old.resolve(['a']).activeActionIds, {'old'});
      final current = MaterialAnalysisSourceGraph([row('a')]);
      expect(current.resolve(['a']).activeActionIds, isEmpty);
      expect(old.resolve(['a']).activeActionIds, {'old'});
    },
  );

  test(
    '10000 linked paths avoid recursion and retain complete source proof',
    () {
      final graph = MaterialAnalysisSourceGraph([
        for (var i = 0; i < 10000; i++)
          row('$i', targets: i == 9999 ? [] : ['${i + 1}']),
      ]);
      final result = graph.resolve(['0']);
      expect(result.complete, isTrue);
      expect(result.materials, hasLength(10000));
    },
  );

  test(
    'downstream quantity text preserves the maximum legal four decimal value',
    () {
      final target = MaterialAnalysisNotificationTarget.fromJson({
        'allocatedQty': 999999999999.9999,
        'quantityFactsExact': {'allocatedQty': '999999999999.9999'},
      });
      expect(target.quantityFactsExact['allocatedQty'], '999999999999.9999');
    },
  );
}
