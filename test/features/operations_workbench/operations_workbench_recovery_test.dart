import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';

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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [connectionRecoveryProvider.overrideWith((ref) => recovery)],
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
