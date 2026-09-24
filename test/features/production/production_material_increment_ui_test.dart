import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/pages/production_material_increment_pages.dart';
import 'package:uten_imp/features/production/repositories/production_material_increment_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

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
  testWidgets('older refresh cannot replace a newer approval result', (
    tester,
  ) async {
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
    repository.newer.complete(
      ProductionMaterialIncrementRequest({
        ..._request().data,
        'status': 'APPROVED',
        'rowVersion': 1,
        'canApprove': false,
        'canReturn': false,
      }),
    );
    await tester.pumpAndSettle();
    repository.older.complete(_request());
    await tester.pumpAndSettle();
    expect(find.textContaining('追加用料已批准'), findsOneWidget);
    expect(find.text('审批通过'), findsNothing);
    expect(tester.takeException(), isNull);
  });
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
        {...((_snapshot(0)['items'] as List).first as Map<String, dynamic>), 'itemId': 'different-demand'},
      ],
    };
    expect(request.snapshotItems('beforeSnapshot'), isNull);
    request.data['beforeSnapshot'] = {
      'items': [
        {...((_snapshot(0)['items'] as List).first as Map<String, dynamic>), 'authorizedQty': null},
      ],
    };
    expect(request.snapshotItems('beforeSnapshot'), isNull);
  });

  testWidgets('failed increment request preserves entered delta and reason', (
    tester,
  ) async {
    final repository = _Repository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
    await tester.enterText(find.byType(TextField).at(0), '30');
    await tester.enterText(find.byType(TextField).at(1), '本批实际需要多用30千克');
    await tester.tap(find.text('提交计划部审批'));
    await tester.pumpAndSettle();
    expect(repository.delta, 30);
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
    expect(find.text('审批前仍按原有额度领料。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
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
  Future<ProductionMaterialIncrementRequest> submit({
    required ProductionMaterialIncrementContext context,
    required Map<String, dynamic> demand,
    required double deltaQty,
    required String reason,
  }) async {
    delta = deltaQty;
    expectedVersion = demand['lockVersion'] as int;
    throw ApiException('CONFLICT', '材料状态已变化，请核对来源');
  }
}

class _DelayedRepository extends _Repository {
  final older = Completer<ProductionMaterialIncrementRequest>();
  final newer = Completer<ProductionMaterialIncrementRequest>();
  int calls = 0;
  @override
  Future<ProductionMaterialIncrementRequest> detail(String id) {
    calls++;
    if (calls == 1) return Future.value(_request());
    return calls == 2 ? older.future : newer.future;
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
