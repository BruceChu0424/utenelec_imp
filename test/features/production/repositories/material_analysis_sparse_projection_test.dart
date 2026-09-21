import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/material_analysis_projection.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  test(
    'full prototype overlays preserve every value including explicit empty facts',
    () {
      final base = _prototype();
      final changed = {
        ...base,
        'materialLineId': 'node-2',
        'requiredQty': 0,
        'availableQty': 0,
        'routeConfirmed': false,
        'sourceConfirmed': null,
        'colorId': null,
        'path': <String>[],
        'downstreamReferences': <Object>[],
        'sharedFutureSupplyRefs': <Object>[],
        'basisOutputQty': null,
        'hardGate': false,
        'minOrderQty': null,
      };
      final defaults = MaterialAnalysisMaterialDefaults(base);
      expect(defaults.hydrate({}), equals(base));
      final sparse = _delta(base, changed);
      final merged = defaults.hydrate(sparse);
      expect(merged, equals(changed));
      expect(merged.containsKey('sourceConfirmed'), isTrue);
      expect(merged['sourceConfirmed'], isNull);
      expect(merged['requiredQty'], 0);
      expect(merged['routeConfirmed'], isFalse);
      expect(merged['path'], isEmpty);
      expect(base['sourceConfirmed'], 'MAKE');
      expect(() => merged['requiredQty'] = 2, throwsUnsupportedError);
    },
  );

  test(
    'v2 v1 and legacy yield equal material identity, quantities and warehouse facts',
    () {
      final base = _prototype();
      final complete = [
        base,
        {
          ...base,
          'materialLineId': 'node-2',
          'requiredQty': 9876543.2109,
          'routeConfirmed': false,
          'sourceConfirmed': null,
          'path': <String>[],
          'borrowRefs': <Object>[],
          'minOrderQty': null,
        },
      ];
      final snapshots = [
        _response(base, [for (final row in complete) _delta(base, row)]),
        {
          'analysisId': 'analysis-1',
          'projection': 'shared-warehouses-v1',
          'warehouseBreakdownsByMaterialKey': _warehouses,
          'flatMaterials': complete,
        },
        {
          'analysisId': 'analysis-1',
          'flatMaterials': [
            for (final row in complete)
              {...row, 'warehouseBreakdown': _warehouses['goods|red|unit']},
          ],
        },
      ].map(ProductionMaterialAnalysisView.fromJson).toList();
      final expected = snapshots.last.materials;
      for (final snapshot in snapshots) {
        for (var i = 0; i < expected.length; i++) {
          final actual = snapshot.materials[i];
          expect(_facts(actual), _facts(expected[i]));
        }
      }
      expect(
        identical(
          snapshots.first.materials.first.warehouseStocks,
          snapshots.first.materials.last.warehouseStocks,
        ),
        isTrue,
      );
      final replay = ProductionMaterialGenerateResult.fromJson({
        'analysis': _response(base, [{}]),
        'replayed': true,
        'plans': [
          {'planId': 'plan-1', 'planNo': 'PP-1'},
        ],
      });
      expect(_facts(replay.analysis.materials.single), _facts(expected.first));
      expect(replay.plans.single.planId, 'plan-1');
    },
  );

  test(
    'malformed sparse values fail closed before domain defaults can hide them',
    () {
      final valid = _response(_prototype(), [{}]);
      for (final response in [
        {...valid}..remove('materialDefaults'),
        {...valid, 'materialDefaults': null},
        {
          ...valid,
          'materialDefaults': {..._prototype()}..remove('requiredQty'),
        },
        {...valid, 'materialDefaults': <Object>[]},
        {
          ...valid,
          'materialDefaults': {1: 2},
        },
        {...valid, 'projection': 'shared-warehouses-v1'},
        {...valid}..remove('projection'),
        {
          ...valid,
          'flatMaterials': null,
          'materials': [_prototype()],
        },
        {
          ...valid,
          'flatMaterials': [null],
        },
        {
          ...valid,
          'flatMaterials': [
            {1: 2},
          ],
        },
        {
          ...valid,
          'flatMaterials': [<String, dynamic>{}, <String, dynamic>{}],
        },
        for (final bad in [
          {'materialLineId': null},
          {'materialLineId': ''},
          {'materialKey': 3},
          {'materialKey': 'unknown'},
          {'requiredQty': '12.4'},
          {'requiredQty': null},
          {'requiredQty': double.nan},
          {'requiredQty': double.infinity},
          {'routeConfirmed': 'false'},
          {'level': 1.5},
          {
            'path': [false],
          },
          {
            'notifiedTargets': [42],
          },
          {
            'downstreamReferences': [false],
          },
          {
            'downstreamReferences': [
              {'allocatedQty': 'bad'},
            ],
          },
          {'warehouseBreakdown': <Object>[]},
        ])
          {
            ...valid,
            'flatMaterials': [bad],
          },
      ]) {
        expect(
          () => ProductionMaterialAnalysisView.fromJson(response),
          throwsFormatException,
        );
      }
      expect(
        ProductionMaterialAnalysisView.fromJson(_response({}, [])).materials,
        isEmpty,
      );
    },
  );

  test(
    'ten thousand sparse paths hydrate without duplicating dimension snapshots',
    () {
      final base = _prototype();
      final response = _response(base, [
        for (var i = 0; i < 10000; i++)
          {'materialLineId': 'node-$i', 'requiredQty': i + 0.0001},
      ]);
      final result = ProductionMaterialAnalysisView.fromJson(response);
      expect(result.materials, hasLength(10000));
      expect(result.materials.last.requiredQty, 9999.0001);
      expect(
        identical(
          result.materials.first.warehouseStocks,
          result.materials.last.warehouseStocks,
        ),
        isTrue,
      );
    },
  );

  test(
    'client explicitly negotiates v2 on reads and writes while accepting v1 fallback',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: request.method == 'GET'
                    ? _response(_prototype(), [{}])
                    : {
                        'analysisId': 'analysis-1',
                        'projection': 'shared-warehouses-v1',
                        'warehouseBreakdownsByMaterialKey': _warehouses,
                        'flatMaterials': [_prototype()],
                      },
              ),
            );
          },
        ),
      );
      final repository = ProductionPlanRepository(ApiClient(dio));
      final view = await repository.materialAnalysisDetail('analysis-1');
      final changed = await repository.updateMaterialAnalysisRoutes(
        analysis: view,
        idempotencyKey: 'route-idempotency',
        decisions: const [],
      );
      expect(_facts(changed.materials.single), _facts(view.materials.single));
      expect(
        requests.map((request) => request.queryParameters['projection']),
        everyElement(materialAnalysisProjectionVersion),
      );
    },
  );
}

Map<String, dynamic> _response(
  Map<String, dynamic> defaults,
  List<Object?> rows,
) => {
  'analysisId': 'analysis-1',
  'projection': materialAnalysisProjectionVersion,
  'materialDefaults': defaults,
  'flatMaterials': rows,
  'warehouseBreakdownsByMaterialKey': _warehouses,
};

Map<String, dynamic> _delta(
  Map<String, dynamic> base,
  Map<String, dynamic> row,
) => {
  for (final entry in row.entries)
    if (!const DeepCollectionEquality().equals(base[entry.key], entry.value))
      entry.key: entry.value,
};

List<Object?> _facts(ProductionMaterialAnalysisMaterial row) => [
  row.materialLineId,
  row.analysisLineId,
  row.nodeKey,
  row.goodsId,
  row.colorId,
  row.unitId,
  row.path,
  row.requiredQty,
  row.perProductQty,
  row.bomQty,
  row.parentPerProductQty,
  row.availableQty,
  row.allocatedAvailableQty,
  row.exactPeggedQty,
  row.externalFutureCoverageQty,
  row.internalCommittedOutputQty,
  row.shortageQty,
  row.demandSupplyGapQty,
  row.additionalSupplyRecommendedQty,
  row.sharedFutureClaimableQty,
  row.plannedOutputQty,
  row.sourceConfirmed,
  row.routeConfirmed,
  row.controlStage,
  row.consumptionBasis,
  row.basisOutputQty,
  row.allowPartialPackage,
  row.hardGate,
  row.minOrderQty,
  row.orderMultipleQty,
  row.owningWarehouseId,
  row.owningWorkshopId,
  row.actionable,
  row.planAnchorAnalysisLineId,
  for (final stock in row.warehouseStocks)
    [
      stock.warehouseId,
      stock.availableQty,
      stock.ownPeggedQty,
      stock.publicAvailableQty,
      stock.openSafetySupplyQty,
    ],
];

Map<String, dynamic> _prototype() => {
  'materialLineId': 'node-1',
  'analysisLineId': 'source-1',
  'nodeKey': 'root/1',
  'actionGroupKey': 'action-1',
  'materialKey': 'goods|red|unit',
  'goodsId': 'goods',
  'goodsCode': 'G-1',
  'goodsName': '精确物料',
  'spec': 'M5',
  'colorId': 'red',
  'colorName': '红',
  'unitId': 'unit',
  'unitName': '件',
  'level': 1,
  'path': ['成品', '精确物料'],
  'parentNodeKey': 'root',
  'parentGoodsId': 'parent',
  'parentLabel': '成品',
  'nodeRole': 'BOM_COMPONENT',
  'controlStage': 'ASSEMBLY',
  'consumptionBasis': 'FIXED_BATCH',
  'basisOutputQty': 12.0001,
  'allowPartialPackage': true,
  'hardGate': true,
  'routeConfirmed': true,
  'actionable': true,
  'lowerLevelPending': false,
  'sourceSuggestion': 'MAKE',
  'sourceConfirmed': 'MAKE',
  'routeReason': null,
  'expectedReadyDate': '2026-09-30',
  'requirementState': 'ACTIVE',
  'delegatedToAnalysisLineId': null,
  'delegatedToSourceRef': null,
  'delegatedToRequestedQty': null,
  'borrowRefs': <Object>[],
  'crossReallocationRefs': <Object>[],
  'notifiedTargets': ['MAKE'],
  'downstreamReferences': <Object>[],
  'sharedFutureSupplyRefs': <Object>[],
  'flowStage': 'WAITING_WORKSHOP',
  'planAnchorAnalysisLineId': 'anchor',
  'subcontractOutboundForm': null,
  'owningWarehouseId': 'leaf',
  'owningWarehouseName': '仓库',
  'owningWorkshopId': 'workshop',
  'owningWorkshopName': '车间',
  'publicSurplusExpectedDate': null,
  'minOrderQty': 3.5,
  'orderMultipleQty': 2,
  for (final field in [
    'bomQty',
    'parentPerProductQty',
    'perProductQty',
    'requiredQty',
    'availableQty',
    'exactPeggedQty',
    'allocatedAvailableQty',
    'reservedQty',
    'safetyStockQty',
    'inboundQty',
    'shortageQty',
    'demandSupplyGapQty',
    'subcontractHandoffFutureQty',
    'borrowedInQty',
    'borrowedOutQty',
    'crossReallocatedInQty',
    'crossReallocatedOutQty',
    'priorityPendingQty',
    'priorityFulfilledQty',
    'publicSurplusApprovedInboundQty',
    'publicSurplusRemainingQty',
    'sharedFutureClaimedQty',
    'additionalSupplyRecommendedQty',
    'selectedWarehousesAvailableQty',
    'selectedOtherWarehouseTransferableQty',
    'mainWarehousePublicAvailableQty',
    'mainWarehouseOpenSafetySupplyQty',
    'mainWarehouseSafetyReplenishmentGapQty',
    'priorityMakeSupplementQty',
    'sharedFuturePendingQty',
    'lateSharedFutureAvailableQty',
    'externalFutureCoverageQty',
    'internalCommittedOutputQty',
  ])
    field: 1234.5678,
};

final _warehouses = <String, dynamic>{
  'goods|red|unit': [
    {
      'warehouseId': 'leaf',
      for (final field in [
        'onHandQty',
        'reservedQty',
        'availableQty',
        'ownPeggedQty',
        'publicAvailableQty',
        'openSafetySupplyQty',
        'safetyReplenishmentGapQty',
        'publicSurplusApprovedInboundQty',
        'publicSurplusRemainingQty',
      ])
        field: 12.3456,
    },
  ],
};
