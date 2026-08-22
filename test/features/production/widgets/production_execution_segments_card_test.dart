import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_execution_planning.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/production_execution_segments_card.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('execution segment model decodes warehouse issue progress', () {
    final segment = ProductionExecutionSegmentView.fromJson(
      _segmentJson(
        status: 'DISPATCHED',
        materialDemandCount: 3,
        materialIssued: false,
      ),
    );

    expect(segment.materialDemandCount, 3);
    expect(segment.fullyIssuedDemandCount, 2);
    expect(segment.materialIssued, isFalse);
  });

  testWidgets('row tap opens execution segment details for read-only users', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('点击任一行查看详情与可用操作'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('执行子计划详情'), findsOneWidget);
    expect(find.text('成品灯 · P-001'), findsOneWidget);
    expect(find.text('当前账号可查看详情，但没有生产操作权限。'), findsOneWidget);
    expect(find.text('调整分配'), findsNothing);
    expect(find.text('派工'), findsNothing);
  });

  testWidgets('detail shows only actions allowed by status and permission', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {
          Perm.productionExecutionAssign,
          Perm.productionExecutionDispatch,
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('调整分配'), findsOneWidget);
    expect(find.text('派工'), findsOneWidget);
    expect(find.text('分批报工'), findsNothing);
  });

  testWidgets('dispatch permission does not imply assignment permission', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {Perm.productionExecutionDispatch},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('派工'), findsOneWidget);
    expect(find.text('调整分配'), findsNothing);
  });

  testWidgets('manual defer can be released and rechecked', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    RequestOptions? command;

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'WAITING',
          autoPromoteWhenReady: false,
          onCommand: (request) => command = request,
        ),
        permissions: const {Perm.productionExecutionReleaseDefer},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('人工暂缓'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('解除人工暂缓'), findsWidgets);
    await tester.tap(find.widgetWithText(UtenButton, '解除人工暂缓'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认解除'));
    await tester.pumpAndSettle();

    expect(command?.path, endsWith('/release-defer'));
    expect(command?.data, containsPair('expectedVersion', 1));
  });

  testWidgets('execution-segment deep link opens one detail dialog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {},
        initialSegmentId: 'segment-1',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('执行子计划详情'), findsOneWidget);
  });

  testWidgets('repeated row taps do not stack detail dialogs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        permissions: const {},
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SEG-001'));
    await tester.tap(find.text('SEG-001'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('执行子计划详情'), findsOneWidget);
  });

  testWidgets('dispatched segment shows pending issue and disables start', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(
          status: 'DISPATCHED',
          fullyIssuedDemandCount: 1,
          materialIssued: false,
        ),
        permissions: const {Perm.productionExecutionStart},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已派工·待发料'), findsOneWidget);
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('待发料 · 1/2 项'), findsOneWidget);
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确认开工'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('fully issued segment enables start and explains the handoff', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'DISPATCHED'),
        permissions: const {Perm.productionExecutionStart},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('已全部发料 · 2/2 项'), findsOneWidget);
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确认开工'))
          .onPressed,
      isNotNull,
    );
  });
}

Widget _app({
  required ProductionPlanRepository repository,
  required Set<String> permissions,
  String? initialSegmentId,
}) {
  return ProviderScope(
    overrides: [productionPlanRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProductionExecutionSegmentsCard(
            planId: 'plan-1',
            canAssign: permissions.contains(Perm.productionExecutionAssign),
            canReleaseDefer: permissions.contains(
              Perm.productionExecutionReleaseDefer,
            ),
            canDispatch: permissions.contains(Perm.productionExecutionDispatch),
            canStart: permissions.contains(Perm.productionExecutionStart),
            canReport: permissions.contains(Perm.productionDailyReportEdit),
            initialSegmentId: initialSegmentId,
          ),
        ),
      ),
    ),
  );
}

ProductionPlanRepository _repository({
  required String status,
  bool autoPromoteWhenReady = true,
  int materialDemandCount = 2,
  int fullyIssuedDemandCount = 2,
  bool materialIssued = true,
  void Function(RequestOptions request)? onCommand,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final isRead = request.method == 'GET';
        if (!isRead) onCommand?.call(request);
        return handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: isRead
                ? [
                    _segmentJson(
                      status: status,
                      autoPromoteWhenReady: autoPromoteWhenReady,
                      materialDemandCount: materialDemandCount,
                      fullyIssuedDemandCount: fullyIssuedDemandCount,
                      materialIssued: materialIssued,
                    ),
                  ]
                : _segmentJson(
                    status: status,
                    materialDemandCount: materialDemandCount,
                    fullyIssuedDemandCount: fullyIssuedDemandCount,
                    materialIssued: materialIssued,
                  ),
          ),
        );
      },
    ),
  );
  return ProductionPlanRepository(ApiClient(dio));
}

Map<String, dynamic> _segmentJson({
  required String status,
  bool autoPromoteWhenReady = true,
  int materialDemandCount = 2,
  int fullyIssuedDemandCount = 2,
  bool materialIssued = true,
}) => {
  'id': 'segment-1',
  'packageId': 'package-1',
  'planId': 'plan-1',
  'sourcePlanItemId': 'plan-item-1',
  'segmentNo': 1,
  'segmentCode': 'SEG-001',
  'productGoodsId': 'goods-1',
  'productCode': 'P-001',
  'productName': '成品灯',
  'productColorId': null,
  'productUnitId': 'unit-1',
  'plannedQty': 10,
  'reportedQty': 3,
  'remainingQty': 7,
  'status': status,
  'autoPromoteWhenReady': autoPromoteWhenReady,
  'workshopDepartmentId': 'workshop-1',
  'workshopName': '装配一车间',
  'teamDepartmentId': 'team-1',
  'teamName': '甲班',
  'responsibleEmployeeId': 'employee-1',
  'responsibleEmployeeName': '张三',
  'planBeginDate': '2026-08-01',
  'planEndDate': '2026-08-02',
  'materialKindCount': 2,
  'shortageKindCount': 0,
  'materialReady': true,
  'materialDemandCount': materialDemandCount,
  'fullyIssuedDemandCount': fullyIssuedDemandCount,
  'materialIssued': materialIssued,
  'lockVersion': 1,
};
