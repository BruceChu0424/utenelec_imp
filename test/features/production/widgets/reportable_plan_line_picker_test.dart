import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/production/models/reportable_plan_line.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/reportable_plan_line_picker.dart';

void main() {
  testWidgets('375px picker blocks replacement and returns REWORK identity', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = ProductionDailyReportRepository(_api());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionDailyReportRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: _PickerHost()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_PickerHost)),
    );
    await tester.tap(find.text('选择来源'));
    await tester.pumpAndSettle();

    expect(find.text('返工再检'), findsOneWidget);
    expect(find.text('报废补产'), findsOneWidget);
    expect(find.text('待补料/待发料'), findsOneWidget);

    final scrap = find.text('报废补产');
    await tester.ensureVisible(scrap);
    await tester.pumpAndSettle();
    await tester.tap(scrap);
    await tester.pumpAndSettle();
    expect(
      container.read(appNotificationProvider).single.message,
      contains('尚未完成新增物料齐套和仓库发料'),
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNull,
    );

    final rework = find.text('返工再检');
    await tester.ensureVisible(rework);
    await tester.pumpAndSettle();
    await tester.tap(rework);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(find.text('已选返工再检 · recovery-rework'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _PickerHost extends ConsumerStatefulWidget {
  const _PickerHost();

  @override
  ConsumerState<_PickerHost> createState() => _PickerHostState();
}

class _PickerHostState extends ConsumerState<_PickerHost> {
  ReportablePlanLine? selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: selected == null
            ? FilledButton(
                onPressed: () async {
                  final result = await showReportablePlanLinePicker(
                    context,
                    ref,
                  );
                  if (mounted && result != null) {
                    setState(() => selected = result);
                  }
                },
                child: const Text('选择来源'),
              )
            : Text(
                '已选${selected!.fqcRecoveryLabel} · '
                '${selected!.fqcRecoveryAuthorizationId}',
              ),
      ),
    );
  }
}

ApiClient _api() {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: {
              'items': [
                _recovery(
                  id: 'recovery-rework',
                  disposition: 'REWORK',
                  maxReportQty: 2,
                  requiresMaterial: false,
                ),
                _recovery(
                  id: 'recovery-scrap',
                  disposition: 'SCRAP',
                  maxReportQty: 0,
                  requiresMaterial: true,
                ),
              ],
              'page': 1,
              'size': 100,
              'total': 2,
              'totalPages': 1,
            },
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _recovery({
  required String id,
  required String disposition,
  required double maxReportQty,
  required bool requiresMaterial,
}) => {
  'planItemId': 'plan-item-1',
  'executionSegmentId': 'segment-1',
  'executionSegmentCode': 'SEG-001',
  'executionSegmentStatus': 'IN_PROGRESS',
  'planNo': 'SJ-001',
  'goodsId': 'goods-1',
  'goodsCode': 'V51043',
  'goodsName': '酸洗插套',
  'unitId': 'unit-1',
  'unitRate': 1,
  'remainingPlanQty': 2,
  'maxReportQty': maxReportQty,
  'fqcRecoveryAuthorizationId': id,
  'fqcRecoveryDispositionCode': disposition,
  'fqcRecoveryAvailableQty': 2,
  'fqcSourceInspectionId': 'inspection-1',
  'fqcSourceReportItemId': 'source-report-item-1',
  'fqcSourceReportNo': 'RB-001',
  'fqcRecoveryRequiresMaterial': requiresMaterial,
};
