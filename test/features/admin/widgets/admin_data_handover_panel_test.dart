import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/admin/widgets/admin_data_handover_panel.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';
import 'package:uten_imp/shared/handover/data_handover_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('manual handover shows four steps and an execution receipt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _HandoverRepositoryFake();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataHandoverRepositoryProvider.overrideWithValue(repository),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(1.2)),
              child: AdminDataHandoverPanel(
                targetEmployeeId: 'target-1',
                targetName: '接手人乙',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('第 1/4 步'), findsOneWidget);

    await tester.tap(find.text('请选择员工'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('交出人甲(E001)'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('admin-data-handover-next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 2/4 步'), findsOneWidget);
    expect(find.text('转移 2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('admin-data-handover-next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 3/4 步'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '岗位调整交接');

    await tester.tap(find.byKey(const ValueKey('admin-data-handover-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认执行'));
    await tester.pumpAndSettle();

    expect(repository.executeCalls, 1);
    expect(find.textContaining('第 4/4 步'), findsOneWidget);
    expect(find.text('交接批次：18'), findsOneWidget);
    expect(find.text('执行回执项次(分类合计)：5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _HandoverRepositoryFake extends DataHandoverRepository {
  _HandoverRepositoryFake()
    : super(ApiClient(Dio(BaseOptions(baseUrl: 'http://localhost'))));

  int executeCalls = 0;

  @override
  Future<PagedResult<DataHandoverCandidate>> candidates({
    required DataHandoverCandidateRole role,
    String? query,
    int page = 1,
    int size = 20,
  }) async => PagedResult(
    items: const [
      DataHandoverCandidate(
        employeeId: 'source-1',
        name: '交出人甲',
        code: 'E001',
        status: 'active',
        departmentName: '销售部',
      ),
    ],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<DataHandoverPreview> adminPreview({
    required String sourceEmployeeId,
    required String targetEmployeeId,
    required Set<String> scopes,
  }) async => DataHandoverPreview(
    sourceEmployeeId: sourceEmployeeId,
    targetEmployeeId: targetEmployeeId,
    scopes: scopes,
    transferCount: 2,
    historyAccessCount: 3,
    releaseCount: 0,
    blockingCount: 0,
    total: 5,
    items: const [
      DataHandoverPreviewItem(
        key: 'client.owner',
        label: '负责客户',
        scope: 'client',
        count: 2,
        action: DataHandoverAction.transfer,
      ),
      DataHandoverPreviewItem(
        key: 'history.client',
        label: '客户历史',
        scope: 'client',
        count: 3,
        action: DataHandoverAction.historyAccess,
      ),
    ],
    hasBlockers: false,
    requiresTarget: true,
  );

  @override
  Future<DataHandoverResult> execute(DataHandoverRequest request) async {
    executeCalls++;
    return DataHandoverResult(
      id: 'handover-1',
      sequenceNo: 18,
      requestId: request.requestId,
      sourceEmployeeId: request.sourceEmployeeId,
      targetEmployeeId: request.targetEmployeeId,
      mode: 'MANUAL',
      status: 'COMPLETED',
      scopes: request.scopes,
      resultSummary: const {'client.owner': 2, 'history.client': 3, 'total': 5},
      replayed: false,
    );
  }
}
