import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/material_priority_replenishment.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/material_priority_replenishment_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _submit = Key('priority-replenishment-submit');
const _quantity = Key('priority-replenishment-quantity');
const _permissions = {
  Perm.productionMaterialAnalysisNotify,
  Perm.productionMaterialAnalysisOverSupply,
  Perm.productionMaterialAnalysisGenerate,
  Perm.productionMaterialAnalysisView,
};

void main() {
  testWidgets(
    'entry and cancellation only preview the exact original plan, retaining the completed transfer',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      expect(repo.previews.single, {
        'sourceAnalysisId': 'source-A',
        'idempotencyKey': 'successful-transfer-key',
      });
      expect(find.text('原供料计划：原计划 A'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(_quantity)).controller?.text,
        '4',
      );
      expect(repo.notifications, isEmpty);
      await tester.tap(find.text('稍后补供'));
      await tester.pumpAndSettle();
      expect(find.text('新计划已满足，调料已完成'), findsOneWidget);
      expect(repo.notifications, isEmpty);
    },
  );

  testWidgets(
    'BUY total seven splits original four and public three on the source UUID',
    (tester) async {
      final repo = _Repository();
      await _pump(tester, repo);
      await tester.enterText(find.byKey(_quantity), '7');
      await tester.tap(
        find.byKey(const Key('priority-replenishment-public-extra')),
      );
      await tester.pumpAndSettle();
      expect(find.text('补原计划 4 · 公共余量 3'), findsOneWidget);
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(repo.notifications.single['analysisId'], 'source-A');
      expect(repo.notifications.single['materialLineIds'], ['source-material']);
      expect(repo.notifications.single['quantities'], [
        {
          'materialLineId': 'source-material',
          'qty': 4.0,
          'safetyReplenishmentQty': 0.0,
          'publicExtraQty': 3.0,
        },
      ]);
      expect(find.text('新计划已满足，调料已完成'), findsOneWidget);
    },
  );

  testWidgets(
    'uncertain replenishment locks the reviewed intent and retries the same key once',
    (tester) async {
      final repo = _Repository()..error = NetworkTimeoutException();
      await _pump(tester, repo);
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(find.text('重试确认补供'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_quantity)).enabled, isFalse);
      expect(
        tester.widget<PopScope>(find.byType(PopScope).last).canPop,
        isFalse,
      );
      repo.error = null;
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(repo.notifications, hasLength(2));
      expect(repo.notifications.first, repo.notifications.last);
      expect(repo.previews, hasLength(1));
    },
  );

  testWidgets(
    'over supply permission is independent and unsupported preparation never accepts public extra',
    (tester) async {
      final repo = _Repository()
        ..json = _preview(route: 'SUBCONTRACT', preparation: true, over: false);
      await _pump(tester, repo, size: const Size(375, 844));
      expect(
        find.byKey(const Key('priority-replenishment-public-extra')),
        findsNothing,
      );
      expect(tester.widget<TextField>(find.byKey(_quantity)).readOnly, isTrue);
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(repo.notifications.single['target'], 'SUBCONTRACT');
      expect(
        (repo.notifications.single['quantities'] as List).single,
        containsPair('publicExtraQty', 0.0),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing local over-supply permission blocks edited excess without a write',
    (tester) async {
      final repo = _Repository();
      await _pump(
        tester,
        repo,
        permissions: {Perm.productionMaterialAnalysisNotify},
      );
      expect(
        find.byKey(const Key('priority-replenishment-public-extra')),
        findsNothing,
      );
      await tester.enterText(find.byKey(_quantity), '7');
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(repo.notifications, isEmpty);
    },
  );

  testWidgets(
    'remaining MAKE responsibility schedules the original child rather than creating it again',
    (tester) async {
      final repo = _Repository()
        ..json = _preview(
          route: 'MAKE',
          remaining: 2,
          over: false,
          child: 'existing-child',
        );
      await _pump(tester, repo);
      expect(
        tester.widget<TextField>(find.byKey(_quantity)).controller?.text,
        '2',
      );
      expect(
        find.byKey(const Key('priority-replenishment-public-extra')),
        findsNothing,
      );
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(repo.plans.single['analysisId'], 'source-A');
      expect(repo.plans.single['lines'], [
        {
          'analysisLineId': 'existing-child',
          'qty': 2.0,
          'departmentId': 'workshop',
          'workshopName': '原车间',
          'workerId': 'worker',
        },
      ]);
      expect(repo.notifications, isEmpty);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  Size size = const Size(1100, 900),
  Set<String> permissions = _permissions,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Text('新计划已满足，调料已完成'),
                TextButton(
                  onPressed: () => showMaterialPriorityReplenishmentDialog(
                    context: context,
                    sourceAnalysisId: 'source-A',
                    sourceMaterialLineId: 'source-material',
                    idempotencyKey: 'successful-transfer-key',
                    sourceLabel: '原计划 A',
                  ),
                  child: const Text('补供'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('补供'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Map<String, dynamic> _preview({
  String route = 'BUY',
  bool preparation = false,
  bool over = true,
  double remaining = 4,
  String? child,
}) => {
  'sourceAnalysis': {
    'analysisId': 'source-A',
    'version': 7,
    'fingerprint': 'source-fingerprint',
    'warehouseId': 'warehouse',
    'flatMaterials': [
      {
        'materialLineId': 'source-material',
        'goodsId': 'goods',
        'goodsName': '原计划物料',
        'unitName': '个',
        'requiredQty': 10,
        'shortageQty': 4,
        'sourceConfirmed': route,
        'routeConfirmed': true,
      },
    ],
    'products': <Map<String, dynamic>>[],
    'allowedActions': ['NOTIFY_SUPPLY', 'GENERATE_PLAN', 'OVER_SUPPLY'],
  },
  'sourceMaterialLineId': 'source-material',
  'targetAnalysisId': 'target-B',
  'transferredQty': 4,
  'priorityPendingQty': 4,
  'remainingSupplementQty': remaining,
  'defaultQty': remaining,
  'route': route,
  'allowedRoutes': [route],
  'operation': route == 'MAKE' ? 'ISSUE_WORKSHOP_PLANS' : 'NOTIFY_SUPPLY',
  'requiresPreparation': preparation,
  'canOverSupply': over,
  'safetyReplenishmentQty': 0,
  'existingChildAnalysisLineId': ?child,
};

class _Repository extends ProductionPlanRepository {
  _Repository() : super(ApiClient(Dio()));
  Map<String, dynamic> json = _preview();
  Object? error;
  final previews = <Map<String, dynamic>>[];
  final notifications = <Map<String, dynamic>>[];
  final plans = <Map<String, dynamic>>[];

  @override
  Future<MaterialPriorityReplenishmentPreview>
  materialPriorityReplenishmentPreview({
    required String sourceAnalysisId,
    String? reallocationId,
    String? idempotencyKey,
    bool futureTransfer = false,
  }) async {
    previews.add({
      'sourceAnalysisId': sourceAnalysisId,
      'reallocationId': ?reallocationId,
      'idempotencyKey': ?idempotencyKey,
    });
    return MaterialPriorityReplenishmentPreview.fromJson(json);
  }

  @override
  Future<ProductionMaterialAnalysisView> notifyMaterialAnalysis({
    required ProductionMaterialAnalysisView analysis,
    required String idempotencyKey,
    required MaterialSupplyRoute target,
    List<String> actionGroupKeys = const [],
    List<String> materialLineIds = const [],
    List<MaterialSupplyQuantityInput> quantities = const [],
  }) async {
    notifications.add({
      'analysisId': analysis.analysisId,
      'version': analysis.version,
      'idempotencyKey': idempotencyKey,
      'target': target.wireName,
      'materialLineIds': materialLineIds,
      'quantities': quantities.map((line) => line.toJson()).toList(),
    });
    if (error != null) throw error!;
    return analysis;
  }

  @override
  Future<
    Map<
      String,
      ({
        String departmentId,
        String? departmentName,
        String? workerId,
        String? workerName,
      })
    >
  >
  defaultWorkshops(Set<String> goodsIds, {CancelToken? cancelToken}) async => {
    'goods': (
      departmentId: 'workshop',
      departmentName: '原车间',
      workerId: 'worker',
      workerName: '原负责人',
    ),
  };

  @override
  Future<ProductionMaterialGenerateResult> issueWorkshopPlans({
    required ProductionMaterialAnalysisView analysis,
    required String warehouseId,
    required String idempotencyKey,
    required String billDate,
    required List<MaterialAnalysisIssueLine> lines,
    String? deliveryDate,
    bool approveNow = false,
  }) async {
    plans.add({
      'analysisId': analysis.analysisId,
      'lines': lines.map((line) => line.toJson()).toList(),
    });
    return ProductionMaterialGenerateResult.fromJson({
      'analysis': json['sourceAnalysis'],
      'plans': <Object>[],
    });
  }
}
