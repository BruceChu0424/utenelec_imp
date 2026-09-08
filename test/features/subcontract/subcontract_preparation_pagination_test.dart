import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_decomposition_page.dart';
import 'package:uten_imp/features/subcontract/providers/subcontract_task_count_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  test(
    'subcontract badge uses authoritative server count above 100 with no preparation list download',
    () async {
      final requests = <String>[];
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request.path);
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: {'count': 257},
                  statusCode: 200,
                ),
              );
            },
          ),
        );
      final container = ProviderContainer(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.subcontractApplicationView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          masterDataSessionKeyProvider.overrideWithValue('test-account'),
          apiClientProvider.overrideWithValue(ApiClient(dio)),
        ],
      );
      addTearDown(container.dispose);
      final loaded = Completer<int>();
      final subscription = container.listen(subcontractTaskCountProvider, (
        _,
        value,
      ) {
        if (value > 0 && !loaded.isCompleted) loaded.complete(value);
      });
      addTearDown(subscription.close);
      await loaded.future.timeout(const Duration(seconds: 5));
      expect(container.read(subcontractTaskCountProvider), 257);
      expect(requests, ['/operations/workbench/subcontract/count']);
    },
  );

  testWidgets(
    'over 100 preparation rows share the existing pager and later-page detail uses exact task id',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = _PagedGateway();
      final details = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              if (request.path.contains('/subcontract-make-tasks/')) {
                details.add(request.path.split('/').last);
                handler.resolve(
                  Response(
                    requestOptions: request,
                    statusCode: 200,
                    data: {
                      'taskId': details.last,
                      'analysisId': 'analysis',
                      'status': 'ACTIVE',
                      'goodsCode': 'SC-101',
                      'goodsName': 'Component101',
                      'workshopStatus': 'NOTIFYING_WORKSHOP',
                      'requiredQty': 10,
                    },
                  ),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: request,
                    statusCode: 200,
                    data: <Object>[],
                  ),
                );
              }
            },
          ),
        );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue({
              Perm.subcontractApplicationView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            apiClientProvider.overrideWithValue(ApiClient(dio)),
          ],
          child: MaterialApp(
            home: SubcontractDecompositionPage(repository: gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('待处理'));
      await tester.pumpAndSettle();
      final seen = <String>{};
      for (var page = 1; page <= 3; page++) {
        final table = tester
            .widget<MasterDataTableView<OperationsWorkbenchTask>>(
              find.byType(MasterDataTableView<OperationsWorkbenchTask>),
            );
        expect(table.currentPage, page);
        expect(table.totalPages, 3);
        expect(table.items.length, page == 3 ? 28 : 50);
        for (final row in table.items) {
          expect(seen.add(row.id), isTrue);
          if (row.preparationTaskId != null) expect(table.idOf!(row), isNull);
        }
        expect(find.text('下一页'), findsOneWidget);
        if (page < 3) {
          await tester.tap(find.text('下一页'));
          await tester.pumpAndSettle();
        }
      }
      expect(seen, hasLength(128));
      expect(seen, contains('prepare-125'));
      expect(gateway.sizes, everyElement(lessThanOrEqualTo(50)));
      final row = find.textContaining('SC-101 Component101');
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(details, ['prepare-101']);
      expect(find.textContaining('产品进度 ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _PagedGateway implements OperationsWorkbenchGateway {
  final sizes = <int>[];
  final rows = [
    for (var i = 1; i <= 128; i++)
      OperationsWorkbenchTask.fromJson({
        'taskId': i <= 125 ? 'prepare-$i' : 'document-$i',
        'supplyRoute': 'SUBCONTRACT',
        'taskStatus': 'WAITING_ORDER',
        'goodsCode': 'SC-$i',
        'goodsName': 'Component$i',
        'requiredQty': 10,
        'openQty': 10,
        if (i <= 125) ...{
          'actionDocType': 'SUBCONTRACT_MAKE_TASK',
          'actionDocId': 'prepare-$i',
          'actionDocCanView': true,
          'actionDocCanEdit': false,
          'actionDocStatus': 'NOTIFYING_WORKSHOP',
        },
      }, OperationsWorkbenchDepartment.subcontract),
  ];
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
    sizes.add(size);
    return OperationsWorkbenchData(
      department: department,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 128,
        overdueTasks: 0,
        openTasks: 128,
        openQty: 1280,
        statusCounts: {'WAITING_ORDER': 128},
        pendingTasks: 128,
      ),
      items: rows.skip((page - 1) * size).take(size).toList(),
      page: page,
      size: size,
      total: 128,
      totalPages: (128 / size).ceil(),
      capabilities: const OperationsWorkbenchCapabilities(),
    );
  }
}
