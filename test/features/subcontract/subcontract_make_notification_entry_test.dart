import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _permissions = {
  Perm.subcontractApplicationView,
  Perm.productionMaterialAnalysisView,
  Perm.productionMaterialAnalysisNotify,
};

void main() {
  testWidgets(
    'first partial output without an application requires both permissions and server capability',
    (tester) async {
      final task = _task();
      final writes = <RequestOptions>[];
      for (final scenario in [
        (
          permissions: {
            Perm.subcontractApplicationView,
            Perm.productionMaterialAnalysisView,
          },
          allowed: true,
        ),
        (permissions: _permissions, allowed: false),
        (permissions: _permissions, allowed: true),
      ]) {
        task['allowedActions'] = scenario.allowed
            ? ['NOTIFY_SUBCONTRACT']
            : <String>[];
        final gateway = await _pump(tester, task, writes, scenario.permissions);
        await _openProgress(tester);
        final action = find.byKey(const Key('subcontract-make-notify-action'));
        if (!scenario.allowed ||
            !scenario.permissions.contains(
              Perm.productionMaterialAnalysisNotify,
            )) {
          expect(action, findsNothing);
          expect(writes, isEmpty);
        } else {
          expect(action, findsOneWidget);
          expect(find.text('查看申请单'), findsNothing);
          final loads = gateway.loads;
          await _submit(tester);
          expect(writes, hasLength(1));
          expect((writes.single.data as Map)['qty'], 4);
          expect(gateway.loads, greaterThan(loads));
          expect(find.textContaining('产品进度 ·'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'reversed notification is reachable again and uses the refreshed ledger identity',
    (tester) async {
      final task = _task();
      final writes = <RequestOptions>[];
      await _pump(tester, task, writes, _permissions);
      await _openProgress(tester);
      await _submit(tester);
      expect(writes, hasLength(1));
      final firstKey = (writes.first.data as Map)['idempotencyKey'];
      task.addAll({
        'notifiedQty': 0,
        'availableQty': 4,
        'allowedActions': ['NOTIFY_SUBCONTRACT'],
        'updatedAt': '2026-09-07T02:00:00Z',
      });
      await tester.tap(find.byTooltip('刷新委外任务'));
      await tester.pumpAndSettle();
      await _openProgress(tester);
      expect(
        find.byKey(const Key('subcontract-make-notify-action')),
        findsOneWidget,
      );
      await _submit(tester);
      expect(writes, hasLength(2));
      expect((writes.last.data as Map)['qty'], 4);
      expect((writes.last.data as Map)['idempotencyKey'], isNot(firstKey));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}

Map<String, dynamic> _task() => {
  'taskId': 'prepare-task',
  'analysisId': 'analysis-1',
  'preparationItemId': 'prepared-item',
  'status': 'ACTIVE',
  'goodsCode': 'SC-PART',
  'goodsName': '委外件首批',
  'requiredQty': 10,
  'producedQty': 4,
  'notifiedQty': 0,
  'availableQty': 4,
  'workshopStatus': 'PRODUCED',
  'allowedActions': ['NOTIFY_SUBCONTRACT'],
  'updatedAt': '2026-09-07T01:00:00Z',
};

Future<_Gateway> _pump(
  WidgetTester tester,
  Map<String, dynamic> task,
  List<RequestOptions> writes,
  Set<String> permissions,
) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final gateway = _Gateway(task);
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        final Object data;
        if (request.method == 'POST' &&
            request.path.endsWith('/prepare-task/notify')) {
          writes.add(request);
          final qty = ((request.data as Map)['qty'] as num).toDouble();
          task['notifiedQty'] = (task['notifiedQty'] as num) + qty;
          task['availableQty'] = (task['availableQty'] as num) - qty;
          task['allowedActions'] = <String>[];
          data = {
            'taskId': 'prepare-task',
            'applicationId': 'application-${writes.length}',
            'applicationBillNo': 'EB-TEST-${writes.length}',
            'notifiedQty': qty,
            'availableQty': task['availableQty'],
          };
        } else if (request.path.endsWith(
          '/subcontract-make-tasks/prepare-task',
        )) {
          data = task;
        } else {
          data = <dynamic>[];
        }
        handler.resolve(
          Response<Object>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(ApiClient(dio)),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SubcontractDecompositionPage(repository: gateway),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('待处理'));
  await tester.pumpAndSettle();
  return gateway;
}

Future<void> _openProgress(WidgetTester tester) async {
  final row = find.textContaining('SC-PART 委外件首批');
  await tester.tap(row);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(row);
  await tester.pumpAndSettle();
  expect(find.textContaining('产品进度 ·'), findsOneWidget);
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('subcontract-make-notify-action')));
  // The guarded action stays busy while its confirmation dialog is open.
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.byKey(const Key('subcontract-make-notify-qty')), findsOneWidget);
  await tester.tap(find.text('确认通知'));
  await tester.pumpAndSettle();
}

class _Gateway implements OperationsWorkbenchGateway {
  _Gateway(this.task);
  final Map<String, dynamic> task;
  int loads = 0;
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
  }) async {
    loads++;
    return OperationsWorkbenchData(
      department: OperationsWorkbenchDepartment.subcontract,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 1,
        overdueTasks: 0,
        openTasks: 1,
        openQty: 0,
        statusCounts: {'WAITING_ORDER': 1},
      ),
      items: [
        OperationsWorkbenchTask.fromJson({
          ...task,
          'supplyRoute': 'SUBCONTRACT',
          'taskStatus': 'WAITING_ORDER',
          'actionDocType': 'SUBCONTRACT_MAKE_TASK',
          'actionDocId': task['taskId'],
          'actionDocCanView': true,
          'actionDocCanEdit': false,
          'actionDocStatus': task['workshopStatus'],
        }, OperationsWorkbenchDepartment.subcontract),
      ],
      page: 1,
      size: 20,
      total: 1,
      totalPages: 1,
      capabilities: const OperationsWorkbenchCapabilities(),
    );
  }
}
