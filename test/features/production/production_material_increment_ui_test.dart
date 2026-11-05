import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/pages/production_material_increment_pages.dart';
import 'package:uten_imp/features/production/repositories/production_material_increment_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';

import '../../support/pump_until.dart';

Map<String, dynamic> _snapshot(int increment) => {
  'items': [
    {
      'itemId': 'demand',
      'goodsName': '原料A',
      'goodsCode': 'MA-1',
      'unitName': '千克',
      'requiredQty': 100,
      'approvedIncrementQty': increment,
      'authorizedQty': 100 + increment,
    },
  ],
};

ProductionMaterialIncrementRequest _request() =>
    ProductionMaterialIncrementRequest({
      'id': 'request',
      'originalDemandId': 'demand',
      'targetSegmentId': 'segment',
      'status': 'PENDING',
      'rowVersion': 0,
      'deltaQty': 30,
      'unitName': '千克',
      'beforeSnapshot': _snapshot(0),
      'afterSnapshot': _snapshot(30),
      'canApprove': true,
      'canReturn': true,
    });

void main() {
  testWidgets(
    'failed return preserves reason and rejects a one-character reason locally',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionMaterialIncrementRepositoryProvider.overrideWithValue(
              _FailingDecisionRepository(),
            ),
          ],
          child: const MaterialApp(
            home: ProductionMaterialIncrementDetailPage(id: 'request'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('退回'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '短');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(
        tester
            .state<FormFieldState<String>>(find.byType(TextFormField))
            .errorText,
        '请填写 2 至 500 字的原因',
      );
      await tester.enterText(find.byType(TextFormField), '请补充实耗依据');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('审批版本发生变化'), findsOneWidget);
      await tester.tap(find.text('退回'));
      await tester.pumpAndSettle();
      expect(find.text('请补充实耗依据'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'planner without workshop permission returns to its own approval list',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionMaterialIncrementRepositoryProvider.overrideWithValue(
              _ApprovedRepository(),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionPlanApprove,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: ProductionMaterialIncrementDetailPage(id: 'request'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('查看车间任务'), findsNothing);
      expect(find.text('返回审批列表'), findsOneWidget);
      expect(find.text('撤销用料授权'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'refresh and approval waiting use overlays and reject repeat actions',
    (tester) async {
      final repository = _DelayedRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionMaterialIncrementRepositoryProvider.overrideWithValue(
              repository,
            ),
          ],
          child: const MaterialApp(
            home: ProductionMaterialIncrementDetailPage(id: 'request'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      await tester.tap(find.byTooltip('刷新'));
      await tester.pump();
      expect(
        repository.calls,
        2,
        reason: 'The busy refresh rejects a second tap',
      );
      expect(find.byType(UtenBusyOverlay), findsWidgets);
      repository.older.complete(_request());
      await tester.pumpAndSettle();
      await tester.tap(find.text('审批通过'));
      await pumpUntil(
        tester,
        () => find.widgetWithText(FilledButton, '确认审核').evaluate().isNotEmpty,
        reason: 'The decision confirmation is available after refresh finishes',
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认审核'));
      await tester.pump();
      expect(repository.decisions, 1);
      expect(find.byType(UtenBusyOverlay), findsWidgets);
      repository.newer.complete(
        ProductionMaterialIncrementRequest({
          ..._request().data,
          'status': 'APPROVED',
          'rowVersion': 1,
          'canApprove': false,
          'canReturn': false,
        }),
      );
      await pumpUntil(
        tester,
        () => find
            .byWidgetPredicate(
              (widget) =>
                  widget is UtenFieldHintIcon &&
                  widget.info?.startsWith('追加用料已批准') == true,
            )
            .evaluate()
            .isNotEmpty,
        reason:
            'The authoritative approval must win before the old read completes',
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenFieldHintIcon &&
              widget.info?.startsWith('追加用料已批准') == true,
        ),
        findsOneWidget,
      );
      expect(find.text('审批通过'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test('comparison requires exact source and complete quantities', () {
    final request = _request();
    expect(
      request.snapshotItems('beforeSnapshot')!.single['authorizedQty'],
      100,
    );
    expect(
      request.snapshotItems('afterSnapshot')!.single['authorizedQty'],
      130,
    );
    request.data['beforeSnapshot'] = {
      'items': [
        {
          ...((_snapshot(0)['items'] as List).first as Map<String, dynamic>),
          'itemId': 'different-demand',
        },
      ],
    };
    expect(request.snapshotItems('beforeSnapshot'), isNull);
    request.data['beforeSnapshot'] = {
      'items': [
        {
          ...((_snapshot(0)['items'] as List).first as Map<String, dynamic>),
          'authorizedQty': null,
        },
      ],
    };
    expect(request.snapshotItems('beforeSnapshot'), isNull);
  });

  testWidgets('failed increment request preserves entered delta and reason', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(repository.api),
          productionMaterialIncrementRepositoryProvider.overrideWithValue(
            repository,
          ),
        ],
        child: const MaterialApp(
          home: ProductionMaterialIncrementCreatePage(segmentId: 'segment'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('increment-quantity-demand')),
      '30',
    );
    await tester.enterText(
      find.byKey(const ValueKey('increment-reason')),
      '本批实际需要多用30千克',
    );
    await tester.tap(find.text('提交计划部审批'));
    await tester.pumpAndSettle();
    expect(
      repository.delta,
      30,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .join(' | '),
    );
    expect(repository.expectedVersion, 5);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('本批实际需要多用30千克'), findsOneWidget);
    expect(find.text('材料状态已变化，请核对来源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('planner sees original red strike and new green authorization', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionMaterialIncrementRepositoryProvider.overrideWithValue(
            _Repository(),
          ),
        ],
        child: const MaterialApp(
          home: ProductionMaterialIncrementDetailPage(id: 'request'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenRevisionStrike), findsOneWidget);
    expect(find.text('− 申请前'), findsOneWidget);
    expect(find.text('+ 申请后'), findsOneWidget);
    expect(find.text('130'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldHintIcon && widget.info == '审批前仍按原有额度领料。',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'multiple material quantities stay frozen across unknown outcomes and retries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _BatchRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(repository.api),
            productionMaterialIncrementRepositoryProvider.overrideWithValue(
              repository,
            ),
          ],
          child: const MaterialApp(
            home: ProductionMaterialIncrementCreatePage(segmentId: 'segment'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('increment-quantity-demand')),
        '30.1250',
      );
      await tester.enterText(
        find.byKey(const ValueKey('increment-quantity-demand-b')),
        '7.5000',
      );
      await tester.enterText(
        find.byKey(const ValueKey('increment-reason')),
        '工单两项材料实际补领',
      );
      await tester.tap(find.text('提交计划部审批'));
      await tester.pump();
      expect(repository.batches.length, 1);
      expect(find.byType(UtenBusyOverlay), findsWidgets);
      expect(repository.batches.single.map((row) => row['deltaQty']), [
        '30.1250',
        '7.5000',
      ]);
      expect(
        repository.batches.single.map((row) => row['expectedDemandVersion']),
        [5, 8],
      );
      repository.pending[0].completeError(ApiException('NETWORK', '连接中断'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('increment-quantity-demand')),
            )
            .enabled,
        false,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('increment-reason')))
            .enabled,
        false,
      );
      await tester.tap(find.text('重试原追加申请'));
      await tester.pump();
      expect(repository.batches.length, 2);
      expect(repository.batches[1], repository.batches[0]);
      repository.pending[1].completeError(
        ApiException(
          'CONFLICT',
          '重试暂未取得原结果',
          httpStatus: 409,
          hasResponseCode: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('重试原追加申请'),
        findsOneWidget,
        reason: 'A refused retry cannot disprove the earlier unknown result',
      );
      expect(find.text('30.1250'), findsOneWidget);
      expect(find.text('7.5000'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a large material context remains scrollable on a narrow screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _BatchRepository(materialCount: 1500);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(repository.api),
            productionMaterialIncrementRepositoryProvider.overrideWithValue(
              repository,
            ),
          ],
          child: const MaterialApp(
            home: ProductionMaterialIncrementCreatePage(segmentId: 'segment'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('increment-reason')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('increment-reason')),
        '窄屏大工单保留原因',
      );
      await tester.ensureVisible(find.text('重新核对来源'));
      await tester.tap(find.text('重新核对来源'));
      await tester.pumpAndSettle();
      expect(find.text('窄屏大工单保留原因'), findsOneWidget);
      expect(repository.batches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quantity validation keeps the exact upper boundary and rejects excess scale',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _BatchRepository(materialCount: 1);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(repository.api),
            productionMaterialIncrementRepositoryProvider.overrideWithValue(
              repository,
            ),
          ],
          child: const MaterialApp(
            home: ProductionMaterialIncrementCreatePage(segmentId: 'segment'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final quantity = find.byKey(const ValueKey('increment-quantity-demand'));
      await tester.enterText(quantity, '99999999999999.9999');
      await tester.enterText(
        find.byKey(const ValueKey('increment-reason')),
        '保留原文精度边界',
      );
      await tester.tap(find.text('提交计划部审批'));
      await tester.pump();
      expect(
        repository.batches.single.single['deltaQty'],
        '99999999999999.9999',
      );
      repository.pending.single.completeError(
        ApiException(
          'CONFLICT',
          '原始数量请核对',
          httpStatus: 409,
          hasResponseCode: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(quantity).enabled, true);
      await tester.enterText(quantity, '0.00001');
      await tester.tap(find.text('提交计划部审批'));
      await tester.pumpAndSettle();
      expect(repository.batches.length, 1);
      expect(find.textContaining('最多4位小数'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'legacy draft quantities require an explicit source check before submission',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(repository.api),
            productionMaterialIncrementRepositoryProvider.overrideWithValue(
              repository,
            ),
          ],
          child: const MaterialApp(
            home: ProductionMaterialIncrementCreatePage(segmentId: 'segment'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state =
          tester.state(find.byType(ProductionMaterialIncrementCreatePage))
              as FormDraftMixin<ProductionMaterialIncrementCreatePage>;
      await state.restoreFormDraft({
        'demandId': 'demand',
        'quantity': '30.2500',
        'reason': '旧草稿继续补领',
      });
      await tester.pumpAndSettle();
      expect(find.text('30.2500'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交计划部审批'))
            .onPressed,
        isNull,
      );
      expect(state.captureFormDraft()['sourceChanged'], true);
      await tester.tap(find.text('重新核对来源'));
      await tester.pumpAndSettle();
      expect(find.text('30.2500'), findsOneWidget);
      expect(find.text('旧草稿继续补领'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交计划部审批'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _BatchRepository extends _Repository {
  _BatchRepository({this.materialCount = 2});
  final int materialCount;
  final batches = <List<Map<String, dynamic>>>[];
  final pending = <Completer<List<ProductionMaterialIncrementRequest>>>[];
  @override
  Future<ProductionMaterialIncrementContext> context(String segmentId) async {
    final source = await super.context(segmentId);
    return ProductionMaterialIncrementContext({
      ...source.data,
      'demands': [
        source.demands.single,
        for (var i = 1; i < materialCount; i++)
          {
            ...source.demands.single,
            'originalDemandId': i == 1 ? 'demand-b' : 'demand-$i',
            'goodsName': '原料$i',
            'goodsCode': 'MA-$i',
            'lockVersion': 8,
          },
      ],
    });
  }

  @override
  Future<List<ProductionMaterialIncrementRequest>> submitBatch(
    List<Map<String, dynamic>> requests,
  ) {
    batches.add(requests.map((row) => Map<String, dynamic>.from(row)).toList());
    final completion = Completer<List<ProductionMaterialIncrementRequest>>();
    pending.add(completion);
    return completion.future;
  }
}

class _Repository extends ProductionMaterialIncrementRepository {
  _Repository() : super(ApiClient(Dio()));
  double? delta;
  int? expectedVersion;
  @override
  Future<ProductionMaterialIncrementContext> context(String segmentId) async =>
      ProductionMaterialIncrementContext({
        'segmentId': segmentId,
        'segmentCode': 'ZX-1',
        'canSubmit': true,
        'demands': [
          {
            'originalDemandId': 'demand',
            'goodsName': '原料A',
            'goodsCode': 'MA-1',
            'unitName': '千克',
            'requiredQty': 100,
            'approvedIncrementQty': 0,
            'netIssuedQty': 100,
            'availableQty': 100,
            'lockVersion': 5,
          },
        ],
      });
  @override
  Future<ProductionMaterialIncrementRequest> detail(String id) async =>
      _request();
  @override
  Future<List<ProductionMaterialIncrementRequest>> submitBatch(
    List<Map<String, dynamic>> requests,
  ) async {
    delta = double.parse(requests.single['deltaQty'].toString());
    expectedVersion = requests.single['expectedDemandVersion'] as int;
    throw ApiException(
      'CONFLICT',
      '材料状态已变化，请核对来源',
      httpStatus: 409,
      hasResponseCode: true,
    );
  }
}

class _DelayedRepository extends _Repository {
  final older = Completer<ProductionMaterialIncrementRequest>();
  final newer = Completer<ProductionMaterialIncrementRequest>();
  int calls = 0;
  int decisions = 0;
  @override
  Future<ProductionMaterialIncrementRequest> detail(String id) {
    calls++;
    if (calls == 1) return Future.value(_request());
    return calls == 2 ? older.future : newer.future;
  }

  @override
  Future<ProductionMaterialIncrementRequest> decide(
    ProductionMaterialIncrementRequest request, {
    required bool approve,
    required String reason,
  }) {
    decisions++;
    return newer.future;
  }
}

class _FailingDecisionRepository extends _Repository {
  @override
  Future<ProductionMaterialIncrementRequest> decide(
    ProductionMaterialIncrementRequest request, {
    required bool approve,
    required String reason,
  }) async => throw ApiException('CONFLICT', '审批版本发生变化');
}

class _ApprovedRepository extends _Repository {
  @override
  Future<ProductionMaterialIncrementRequest> detail(String id) async =>
      ProductionMaterialIncrementRequest({
        ..._request().data,
        'status': 'APPROVED',
        'canApprove': false,
        'canReturn': false,
        'canCancel': true,
      });
}
