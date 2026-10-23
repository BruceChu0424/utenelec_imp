import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/production/models/material_aggregate_order.dart';

void main() {
  test(
    'aggregate preview yields within a large source group and keeps facts',
    () async {
      final json = _preview();
      var inputHandled = false;
      Timer.run(() => inputHandled = true);
      final result = await MaterialAggregateOrderPreview.fromJsonResponsive(
        json,
        budget: UiWorkBudget(maxItems: 64),
      );
      final sync = MaterialAggregateOrderPreview.fromJson(json);
      expect(inputHandled, isTrue);
      expect(result.analysis.analysisId, sync.analysis.analysisId);
      expect(result.groups.single.sources.length, 10000);
      for (var i = 0; i < 10000; i++) {
        final actual = result.groups.single.sources[i];
        final expected = sync.groups.single.sources[i];
        expect(actual.materialLineId, expected.materialLineId);
        expect(
          actual.originalMaterialLineIds,
          expected.originalMaterialLineIds,
        );
        expect(actual.allocatedQtyExact, expected.allocatedQtyExact);
        expect(actual.allocatedQty, expected.allocatedQty);
      }
      expect(result.groups.single.sharedBomChildren.last.goodsId, 'child-999');
      expect(result.groups.single.publicExtraQtyExact, '123.0001');
    },
  );

  test(
    'aggregate result batches yield without merging source identities',
    () async {
      final json = <String, dynamic>{
        'analysis': {'analysisId': 'a'},
        'replayed': true,
        'batches': [
          {'clientGroupKey': 'g', 'sources': _sources()},
        ],
        'materialIdentityBridges': [
          {
            'fromMaterialLineIds': ['a', 'b'],
            'toMaterialLineId': 'c',
            'requiredQty': 0.0001,
          },
        ],
      };
      var inputHandled = false;
      Timer.run(() => inputHandled = true);
      final result = await MaterialAggregateOrderResult.fromJsonResponsive(
        json,
        budget: UiWorkBudget(maxItems: 64),
      );
      expect(inputHandled, isTrue);
      expect(result.replayed, isTrue);
      expect(result.batches.single.sources.last.materialLineId, 'line-9999');
      expect(result.materialIdentityBridges.single.fromMaterialLineIds, [
        'a',
        'b',
      ]);
      expect(result.materialIdentityBridges.single.requiredQty, 0.0001);
    },
  );

  test(
    'cancelling during nested source decoding never returns a partial preview',
    () async {
      var current = true;
      Timer.run(() => current = false);
      await expectLater(
        MaterialAggregateOrderPreview.fromJsonResponsive(
          _preview(),
          budget: UiWorkBudget(maxItems: 64, isCurrent: () => current),
        ),
        throwsA(isA<UiWorkCancelled>()),
      );
    },
  );
}

List<Map<String, dynamic>> _sources() => List.generate(
  10000,
  (i) => {
    'materialLineId': 'line-$i',
    'originalMaterialLineIds': ['original-$i', 'second-$i'],
    'allocatedQty': 123.0001,
    'allocatedQtyExact': '123.0001',
  },
);

Map<String, dynamic> _preview() => {
  'analysis': {'analysisId': 'a'},
  'analysisId': 'a',
  'version': 1,
  'fingerprint': 'f',
  'previewFingerprint': 'pf',
  'groups': [
    {
      'clientGroupKey': 'g',
      'goodsId': 'goods',
      'publicExtraQtyExact': '123.0001',
      'sources': _sources(),
      'sharedBomChildren': List.generate(1000, (i) => {'goodsId': 'child-$i'}),
    },
  ],
};
