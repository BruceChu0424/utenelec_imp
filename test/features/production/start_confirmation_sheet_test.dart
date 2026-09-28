// 开工确认表 (ADR-131 §5.4) widget 测试。
//
// 覆盖: 老库材质预填来源; 双料多选; 「不用内料仓的料」选项列出料名;
// 「还要按工单领别的料」只对可勾的产品出现, 勾了的行不进开工而转领料;
// 确认后按「认料 → 路线 → 开工」顺序调仓储; 中途失败保留输入并可重试同键。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/repositories/workshop_material_choice_repository.dart';
import 'package:uten_imp/features/production/widgets/start_confirmation_sheet.dart';

const _pp = WorkshopMaterialOption(
  goodsId: 'pp',
  goodsCode: 'PP-01',
  goodsName: 'PP',
  colorName: '黑',
);
const _abs = WorkshopMaterialOption(
  goodsId: 'abs',
  goodsCode: 'ABS-01',
  goodsName: 'ABS',
  colorName: '白',
);

ProductionExecutionWorkbenchSegment _task(
  String id,
  String product, {
  String? startRoute,
  String? suggestedStartRoute = 'FULL_KIT',
  String binState = 'NEED_CHOICE',
}) => ProductionExecutionWorkbenchSegment.fromJson({
  'segmentId': id,
  'planId': 'plan-$id',
  'planNo': 'SJ-$id',
  'segmentCode': 'GD-$id',
  'workshopDepartmentId': 'workshop-1',
  'workshopName': '注塑车间',
  'productCode': 'P-$id',
  'productName': product,
  'plannedQty': 100,
  'segmentStatus': 'READY',
  'materialStatus': 'KIT_READY',
  'preparationStatus': 'PREPARED',
  'zeroMaterial': true,
  'lockVersion': 3,
  'startRoute': startRoute,
  'suggestedStartRoute': suggestedStartRoute,
  'suggestedStartRouteSource': suggestedStartRoute == null ? null : 'PRODUCT',
  'binMaterialState': binState,
  'needsStartConfirmation': true,
  'allowedActions': ['CHOOSE'],
});

WorkshopMaterialPendingChoice _pending(
  String product,
  List<String> segmentIds, {
  bool choiceRequired = true,
  List<WorkshopMaterialRef> prefill = const [],
  String? prefillSource,
  bool alsoOrderAllowed = true,
  List<WorkshopMaterialBomWeight> bomWeights = const [],
}) => WorkshopMaterialPendingChoice(
  workshopDepartmentId: 'workshop-1',
  workshopName: '注塑车间',
  productGoodsId: product,
  productCode: 'CODE-$product',
  productName: '产品 $product',
  segmentIds: segmentIds,
  taskCount: segmentIds.length,
  choiceRequired: choiceRequired,
  prefill: prefill,
  prefillSource: prefillSource,
  options: const [_pp, _abs],
  bomWeights: bomWeights,
  alsoOrderMaterialsAllowed: alsoOrderAllowed,
);

class _ChooseCall {
  _ChooseCall(this.workshopDepartmentId, this.choices, this.idempotencyKey);
  final String workshopDepartmentId;
  final List<WorkshopMaterialProductChoice> choices;
  final String idempotencyKey;
}

class _FakeChoiceRepository extends WorkshopMaterialChoiceRepository {
  _FakeChoiceRepository(this.calls, this.rows) : super(ApiClient(Dio()));

  final List<String> calls;
  final List<WorkshopMaterialPendingChoice> rows;
  final List<_ChooseCall> chosen = [];
  int failChooseTimes = 0;

  @override
  Future<List<WorkshopMaterialPendingChoice>> pending(
    List<String> segmentIds,
  ) async => rows;

  @override
  Future<void> choose({
    required String workshopDepartmentId,
    required List<WorkshopMaterialProductChoice> choices,
    required String idempotencyKey,
  }) async {
    calls.add('choose');
    chosen.add(_ChooseCall(workshopDepartmentId, choices, idempotencyKey));
    if (failChooseTimes > 0) {
      failChooseTimes--;
      throw ApiException('NETWORK', '网络断了，请重试');
    }
  }
}

class _FakePlanRepository extends ProductionPlanRepository {
  _FakePlanRepository(this.calls)
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'))));

  final List<String> calls;
  final List<({String segmentId, int expectedVersion})> startedItems = [];

  @override
  Future<ProductionExecutionSegmentView> confirmExecutionSegmentRoute(
    String planId,
    String segmentId, {
    required int expectedVersion,
    required String route,
  }) async {
    calls.add('route:$segmentId:$route');
    return ProductionExecutionSegmentView.fromJson({
      'id': segmentId,
      'packageId': 'package',
      'planId': planId,
      'sourcePlanItemId': 'plan-item',
      'segmentCode': 'SEG-1',
      'productGoodsId': 'goods',
      'plannedQty': 100,
      'reportedQty': 0,
      'remainingQty': 100,
      'lockVersion': expectedVersion + 1,
      'status': 'READY',
    });
  }

  @override
  Future<void> batchStartExecutionSegments(
    String planId, {
    required List<({String segmentId, int expectedVersion})> items,
  }) async {
    calls.add('start:$planId');
    startedItems.addAll(items);
  }
}

class _Harness {
  _Harness(this.choices, this.plans, this.calls);
  final _FakeChoiceRepository choices;
  final _FakePlanRepository plans;
  final List<String> calls;
  StartConfirmationOutcome? outcome;
  bool closed = false;
}

Future<_Harness> _open(
  WidgetTester tester, {
  required List<ProductionExecutionWorkbenchSegment> tasks,
  required List<WorkshopMaterialPendingChoice> rows,
}) async {
  // 用 view 尺寸 (而不是 setSurfaceSize): 侧板宽度按 MediaQuery 算, 两者要一致。
  tester.view
    ..physicalSize = const Size(1800, 1100)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final calls = <String>[];
  final harness = _Harness(
    _FakeChoiceRepository(calls, rows),
    _FakePlanRepository(calls),
    calls,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        workshopMaterialChoiceRepositoryProvider.overrideWithValue(
          harness.choices,
        ),
        productionPlanRepositoryProvider.overrideWithValue(harness.plans),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                harness.outcome = await showStartConfirmationSheet(
                  context,
                  tasks: tasks,
                );
                harness.closed = true;
              },
              child: const Text('打开确认表'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开确认表'));
  await tester.pumpAndSettle();
  expect(find.text('开工前确认用料'), findsOneWidget);
  return harness;
}

Future<void> _pickMaterial(
  WidgetTester tester,
  String product,
  List<String> optionKeys,
) async {
  await tester.tap(find.byKey(ValueKey('start-sheet-material-$product')));
  await tester.pumpAndSettle();
  for (final key in optionKeys) {
    await tester.tap(find.byKey(ValueKey('start-sheet-option-$product-$key')));
    await tester.pump();
  }
  await tester.tap(find.byKey(const Key('start-sheet-material-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('prefill from the legacy material text is shown and submitted '
      'in order: choose, then route, then start', (tester) async {
    final harness = await _open(
      tester,
      tasks: [_task('seg-1', '产品 A')],
      rows: [
        _pending(
          'A',
          ['seg-1'],
          prefill: const [WorkshopMaterialRef(goodsId: 'pp')],
          prefillSource: workshopMaterialPrefillLegacyText,
        ),
      ],
    );
    expect(find.text('按老库材质预填，请核对'), findsOneWidget);
    expect(find.text('PP 黑'), findsWidgets);
    // 单个重量没填: 显示「待补, 不影响开工」。
    expect(find.text('待补, 不影响开工'), findsWidgets);

    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();

    expect(harness.calls, [
      'choose',
      'route:seg-1:FULL_KIT',
      'start:plan-seg-1',
    ]);
    final choice = harness.choices.chosen.single.choices.single;
    expect(choice.kind, workshopMaterialChoiceKindMaterial);
    expect(choice.materials, const [WorkshopMaterialRef(goodsId: 'pp')]);
    expect(choice.prefillSource, workshopMaterialPrefillLegacyText);
    // 开工用确认路线后的新版本。
    expect(harness.plans.startedItems.single.expectedVersion, 4);
    expect(harness.closed, isTrue);
    expect(harness.outcome?.startedSegmentIds, {'seg-1'});
    expect(harness.outcome?.drawSegmentIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two materials can be picked for a two-shot product', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      tasks: [_task('seg-1', '产品 A')],
      rows: [
        _pending(
          'A',
          ['seg-1'],
          prefill: const [WorkshopMaterialRef(goodsId: 'pp')],
        ),
      ],
    );
    expect(find.text('按上次选的料预填，请核对'), findsOneWidget);
    await _pickMaterial(tester, 'A', ['abs|']);
    expect(find.text('PP 黑、ABS 白'), findsWidgets);
    expect(find.text('按上次选的料预填，请核对'), findsNothing);

    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();

    final choice = harness.choices.chosen.single.choices.single;
    expect(choice.materials, const [
      WorkshopMaterialRef(goodsId: 'pp'),
      WorkshopMaterialRef(goodsId: 'abs'),
    ]);
    expect(choice.prefillSource, isNull, reason: '改过就不是预填值');
    expect(tester.takeException(), isNull);
  });

  testWidgets('"not from the store" lists every material the store takes and '
      'sends a no-BOM product to material requisition instead of starting', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      tasks: [_task('seg-1', '产品 A')],
      rows: [
        _pending('A', ['seg-1']),
      ],
    );
    // 没选用料: 必填红框, 开工数为 0。
    expect(find.text('确认并开工 (0)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('start-sheet-material-A')));
    await tester.pumpAndSettle();
    expect(find.text('本产品不用车间内料仓的料 (按工单领料)'), findsOneWidget);
    expect(find.text('本车间内料仓收的料：PP 黑、ABS 白'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-sheet-option-A-none')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-sheet-material-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('先按工单领料，暂不开工'), findsWidgets);
    expect(find.text('确认并开工 (0)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-confirmation-order-instead')));
    await tester.pumpAndSettle();

    expect(harness.calls, ['choose', 'route:seg-1:FULL_KIT']);
    expect(
      harness.choices.chosen.single.choices.single.kind,
      workshopMaterialChoiceKindNone,
    );
    expect(harness.outcome?.startedSegmentIds, isEmpty);
    expect(harness.outcome?.drawSegmentIds, ['seg-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"also issue other materials" only shows for products without '
      'BOM; a checked row is not started but sent to requisition', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      tasks: [_task('seg-1', '产品 A'), _task('seg-2', '产品 B')],
      rows: [
        _pending(
          'A',
          ['seg-1'],
          prefill: const [WorkshopMaterialRef(goodsId: 'pp')],
        ),
        _pending(
          'B',
          ['seg-2'],
          prefill: const [WorkshopMaterialRef(goodsId: 'abs')],
          alsoOrderAllowed: false,
          bomWeights: const [
            WorkshopMaterialBomWeight(goodsId: 'abs', unitWeightGrams: 12.5),
          ],
        ),
      ],
    );
    expect(
      find.byKey(const ValueKey('start-sheet-also-order-A')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('start-sheet-also-order-B')),
      findsNothing,
    );
    expect(find.text('12.5 克'), findsWidgets);
    expect(find.text('确认并开工 (2)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('start-sheet-also-order-A')));
    await tester.pumpAndSettle();
    expect(find.text('先按工单领料，暂不开工'), findsWidgets);
    expect(find.text('确认并开工 (1)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();

    expect(harness.calls, [
      'choose',
      'route:seg-1:FULL_KIT',
      'route:seg-2:FULL_KIT',
      'start:plan-seg-2',
    ]);
    final byProduct = {
      for (final choice in harness.choices.chosen.single.choices)
        choice.productGoodsId: choice,
    };
    expect(byProduct['A']!.alsoOrderMaterials, isTrue);
    expect(byProduct['B']!.alsoOrderMaterials, isFalse);
    expect(harness.outcome?.startedSegmentIds, {'seg-2'});
    expect(harness.outcome?.drawSegmentIds, ['seg-1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failure keeps the input and a retry reuses the same key', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      tasks: [_task('seg-1', '产品 A')],
      rows: [
        _pending(
          'A',
          ['seg-1'],
          prefill: const [WorkshopMaterialRef(goodsId: 'pp')],
        ),
      ],
    );
    harness.choices.failChooseTimes = 1;
    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-confirmation-error')), findsOneWidget);
    expect(find.text('网络断了，请重试'), findsOneWidget);
    expect(find.text('开工前确认用料'), findsOneWidget, reason: '表格不关');
    expect(find.text('PP 黑'), findsWidgets, reason: '已选的料原样保留');
    expect(harness.calls, ['choose']);
    expect(harness.closed, isFalse);

    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();

    expect(harness.calls, [
      'choose',
      'choose',
      'route:seg-1:FULL_KIT',
      'start:plan-seg-1',
    ]);
    expect(
      harness.choices.chosen[1].idempotencyKey,
      harness.choices.chosen[0].idempotencyKey,
    );
    expect(harness.closed, isTrue);
    expect(harness.outcome?.startedSegmentIds, {'seg-1'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row that only needs a route shows the material as settled', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      tasks: [_task('seg-1', '产品 A', binState: 'NO_BIN')],
      rows: [
        _pending('A', ['seg-1'], choiceRequired: false),
      ],
    );
    expect(find.text('用料已定'), findsWidgets);
    expect(find.byKey(const ValueKey('start-sheet-material-A')), findsNothing);
    await tester.tap(find.byKey(const Key('start-confirmation-submit')));
    await tester.pumpAndSettle();
    expect(harness.calls, ['route:seg-1:FULL_KIT', 'start:plan-seg-1']);
    expect(tester.takeException(), isNull);
  });
}
