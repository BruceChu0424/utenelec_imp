import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/production_execution_segments_card.dart';

void main() {
  testWidgets('row tap opens execution segment details for read-only users', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        repository: _repository(status: 'READY'),
        canEdit: false,
        canReport: false,
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
        canEdit: true,
        canReport: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SEG-001'));
    await tester.pumpAndSettle();

    expect(find.text('调整分配'), findsOneWidget);
    expect(find.text('派工'), findsOneWidget);
    expect(find.text('分批报工'), findsNothing);
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
        canEdit: true,
        canReport: false,
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
        canEdit: false,
        canReport: false,
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
        canEdit: false,
        canReport: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SEG-001'));
    await tester.tap(find.text('SEG-001'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('执行子计划详情'), findsOneWidget);
  });
}

Widget _app({
  required ProductionPlanRepository repository,
  required bool canEdit,
  required bool canReport,
  String? initialSegmentId,
}) {
  return ProviderScope(
    overrides: [productionPlanRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProductionExecutionSegmentsCard(
            planId: 'plan-1',
            canEdit: canEdit,
            canReport: canReport,
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
                    ),
                  ]
                : _segmentJson(status: status),
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
  'lockVersion': 1,
};
