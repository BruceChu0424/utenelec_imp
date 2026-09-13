import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';

void main() {
  test('shared and legacy snapshots preserve every warehouse fact', () {
    final shared = ProductionMaterialAnalysisView.fromJson(_shared());
    final legacy = ProductionMaterialAnalysisView.fromJson({
      'analysisId': 'analysis-1',
      'flatMaterials': [
        for (final row in _materials) {...row, 'warehouseBreakdown': _stocks},
      ],
    });
    for (var i = 0; i < shared.materials.length; i++) {
      final actual = shared.materials[i];
      final original = legacy.materials[i];
      expect(actual.materialLineId, original.materialLineId);
      expect(actual.analysisLineId, original.analysisLineId);
      expect(actual.requiredQty, original.requiredQty);
      expect(actual.shortageQty, original.shortageQty);
      expect(actual.routeConfirmed, isFalse);
      expect(actual.warehouseStocks.length, 2);
      final stocked = actual.warehouseStocks.first;
      expect(stocked.warehouseId, 'leaf-1');
      expect(stocked.availableQty, 12.3456);
      expect(stocked.ownPeggedQty, 2.0001);
      expect(stocked.publicAvailableQty, 10.3455);
      expect(stocked.openSafetySupplyQty, 3.4567);
      expect(stocked.safetyReplenishmentGapQty, 0.1234);
      expect(stocked.publicSurplusApprovedInboundQty, 8.7654);
      expect(stocked.publicSurplusRemainingQty, 6.5432);
      expect(stocked.publicSurplusExpectedDate, '2026-09-30');
      expect(actual.warehouseStocks.last.warehouseId, 'empty-leaf');
      expect(actual.warehouseStocks.last.availableQty, 0);
    }
    expect(
      identical(
        shared.materials.first.warehouseStocks,
        shared.materials.last.warehouseStocks,
      ),
      isTrue,
    );
    expect(
      () => shared.materials.first.warehouseStocks.clear(),
      throwsUnsupportedError,
    );
  });

  test('many BOM paths decode one immutable dimension list', () {
    final response = _shared();
    response['flatMaterials'] = [
      for (var i = 0; i < 1000; i++)
        {
          ..._materials.first,
          'materialLineId': 'node-$i',
          'requiredQty': i + 0.0001,
        },
    ];
    final result = ProductionMaterialAnalysisView.fromJson(response);
    expect(result.materials.length, 1000);
    for (var i = 0; i < result.materials.length; i++) {
      expect(result.materials[i].requiredQty, i + 0.0001);
      expect(
        identical(
          result.materials.first.warehouseStocks,
          result.materials[i].warehouseStocks,
        ),
        isTrue,
      );
    }
  });

  test('different dimensions never share balances', () {
    final response = _shared();
    response['warehouseBreakdownsByMaterialKey'] = {
      'goods|NONE|unit': _stocks,
      'goods|blue|unit': <Map<String, dynamic>>[],
    };
    response['flatMaterials'] = [
      _materials.first,
      {..._materials.last, 'materialKey': 'goods|blue|unit'},
    ];
    final result = ProductionMaterialAnalysisView.fromJson(response);
    expect(result.materials.first.warehouseStocks.length, 2);
    expect(result.materials.last.warehouseStocks, isEmpty);
  });

  test(
    'missing or unknown shared data fails instead of displaying zero stock',
    () {
      for (final bad in [
        {..._shared(), 'warehouseBreakdownsByMaterialKey': null},
        {..._shared(), 'warehouseBreakdownsByMaterialKey': <String, dynamic>{}},
        {..._shared(), 'projection': 'shared-warehouses-v2'},
        {..._shared(), 'projection': null},
        {..._shared()}..remove('projection'),
        {..._shared(), 'flatMaterials': null},
        {
          ..._shared(),
          'flatMaterials': [42],
        },
        {
          ..._shared(),
          'warehouseBreakdownsByMaterialKey': {'goods|NONE|unit': 'invalid'},
        },
        {
          ..._shared(),
          'warehouseBreakdownsByMaterialKey': {
            'goods|NONE|unit': [42],
          },
        },
        for (final rows in [
          [<String, dynamic>{}],
          [
            {..._stocks.first, 'warehouseId': ''},
          ],
          [
            {..._stocks.first, 'availableQty': 'bad'},
          ],
          [
            {..._stocks.first, 'reservedQty': null},
          ],
          [
            {..._stocks.first, 'ownPeggedQty': double.nan},
          ],
          [
            {..._stocks.first, 'onHandQty': double.infinity},
          ],
          [_stocks.first, _stocks.first],
        ])
          {
            ..._shared(),
            'warehouseBreakdownsByMaterialKey': {'goods|NONE|unit': rows},
          },
      ]) {
        expect(
          () => ProductionMaterialAnalysisView.fromJson(bad),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'workshop replay decodes its nested shared snapshot without changing plans',
    () {
      final result = ProductionMaterialGenerateResult.fromJson({
        'analysis': _shared(),
        'replayed': true,
        'plans': [
          {'planId': 'plan-1', 'planNo': 'P-1', 'status': 'APPROVED'},
        ],
      });
      expect(result.plans.single.planId, 'plan-1');
      expect(
        result.analysis.materials.first.warehouseStocks.first.availableQty,
        12.3456,
      );
    },
  );
}

Map<String, dynamic> _shared() => {
  'analysisId': 'analysis-1',
  'projection': 'shared-warehouses-v1',
  'warehouseBreakdownsByMaterialKey': {'goods|NONE|unit': _stocks},
  'flatMaterials': _materials,
};

const _materials = [
  {
    'materialLineId': 'material-1',
    'analysisLineId': 'source-1',
    'materialKey': 'goods|NONE|unit',
    'nodeKey': 'root/1',
    'requiredQty': 10.0001,
    'shortageQty': 8.0,
    'routeConfirmed': false,
  },
  {
    'materialLineId': 'material-2',
    'analysisLineId': 'source-2',
    'materialKey': 'goods|NONE|unit',
    'nodeKey': 'root/1',
    'requiredQty': 20.0001,
    'shortageQty': 18.0,
    'routeConfirmed': false,
  },
];

const _stocks = [
  {
    'warehouseId': 'leaf-1',
    'warehouseCode': 'W-1',
    'warehouseName': '实际仓',
    'onHandQty': 15.3456,
    'reservedQty': 3.0,
    'availableQty': 12.3456,
    'ownPeggedQty': 2.0001,
    'publicAvailableQty': 10.3455,
    'openSafetySupplyQty': 3.4567,
    'safetyReplenishmentGapQty': 0.1234,
    'publicSurplusApprovedInboundQty': 8.7654,
    'publicSurplusRemainingQty': 6.5432,
    'publicSurplusExpectedDate': '2026-09-30',
  },
  {
    'warehouseId': 'empty-leaf',
    'warehouseName': '零库存仓',
    'onHandQty': 0.0,
    'reservedQty': 0.0,
    'availableQty': 0.0,
    'ownPeggedQty': 0.0,
    'publicAvailableQty': 0.0,
    'openSafetySupplyQty': 0.0,
    'safetyReplenishmentGapQty': 0.0,
    'publicSurplusApprovedInboundQty': 0.0,
    'publicSurplusRemainingQty': 0.0,
  },
];
