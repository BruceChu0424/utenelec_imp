import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  testWidgets('open workbench reloads itself after connection recovery', (
    tester,
  ) async {
    final gateway = _RecoveringGateway();
    final recovery = ConnectionRecoveryController(
      probe: () async => true,
      probeDelays: const [Duration(hours: 1)],
      restoredDisplayDuration: const Duration(hours: 1),
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionRecoveryProvider.overrideWith((ref) => recovery),
          // ADR-184：阶段红黄数与徽章汇总链路需要 prefs；本用例不断言红黄数，
          // 事实全 0（无自动选中，保持仅初始加载一次）。
          sharedPreferencesProvider.overrideWithValue(prefs),
          // 覆写 prefs 后真实 api 链路（仓库字典预热）会在测试环境挂起，
          // 注入假 api 让预热走空数据。
          apiClientProvider.overrideWithValue(_FakeApi()),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              facts: const {
                BadgeFact.purchaseTaskWaitingOrder: 0,
                BadgeFact.purchaseTaskRework: 0,
                BadgeFact.purchaseTaskInProgress: 0,
              },
            ),
          ),
        ],
        child: MaterialApp(
          home: OperationsWorkbenchPage(
            department: OperationsWorkbenchDepartment.purchase,
            repository: gateway,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.calls, 1);
    expect(find.text('网络暂时不可用'), findsOneWidget);

    recovery.markDisconnected();
    await recovery.retryNow();
    await tester.pumpAndSettle();

    expect(gateway.calls, 2);
    expect(find.text('网络暂时不可用'), findsNothing);
  });
}

/// 其余请求（徽章、仓库字典预热等）一律回空, 不走真网络（ADR-184 起覆写
/// sharedPreferencesProvider 后, 真实 api 链路在测试环境会挂起加载）。
class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio(BaseOptions(baseUrl: 'http://localhost:8080/api')));

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'items': <Object?>[], 'page': 1, 'total': 0, 'totalPages': 1};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

class _RecoveringGateway implements OperationsWorkbenchGateway {
  var calls = 0;

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async {
    calls++;
    if (calls == 1) {
      throw NetworkException('网络暂时不可用');
    }
    return OperationsWorkbenchData(
      department: department,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 0,
        overdueTasks: 0,
        openTasks: 0,
        openQty: 0,
        statusCounts: {},
      ),
      items: const [],
      page: 1,
      size: size,
      total: 0,
      totalPages: 0,
      capabilities: const OperationsWorkbenchCapabilities(),
    );
  }
}
