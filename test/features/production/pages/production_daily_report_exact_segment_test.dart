import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_edit_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/repositories/production_actual_output_supplement_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';

void main() {
  for (final scenario in ['complete', 'wrong-source', 'duplicate-active']) {
    testWidgets('approval resume restores exact whole input: $scenario', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      Map<String, dynamic>? saved;
      final sourceRequests = <RequestOptions>[];
      Map<String, dynamic> source(int i) => {
        'planId': 'plan-$i',
        'planItemId': 'item-$i',
        'executionSegmentId': 'segment-$i',
        'executionSegmentCode': 'ZX-$i',
        'planNo': 'SJ-$i',
        'goodsId': 'goods-1',
        'goodsName': '同品多来源',
        'unitId': 'unit-1',
        'unitRate': 1,
        'maxReportQty': i == 2 ? 2 : 0,
        'allowActualOverproduction': i != 2,
        if (i == 2) ...{
          'fqcRecoveryAuthorizationId': 'recovery-1',
          'fqcRecoveryDispositionCode': 'REWORK',
          'fqcRecoveryAvailableQty': 2,
        },
      };
      final snapshot = {
        'idempotencyKey': 'captured-report-key',
        'billDate': '2026-09-24',
        'departmentId': 'workshop',
        'workshopName': '装配第一车间',
        'remark': '申请时整单备注',
        'workerIds': ['employee-1'],
        'items': [
          for (var i = 0; i < 3; i++)
            {
              'planItemId': 'item-$i',
              'executionSegmentId': 'segment-$i',
              'goodsId': 'goods-1',
              'unitId': 'unit-1',
              'unitRate': 1,
              'qty': i == 0 ? 130 : (i == 1 ? 5 : 2),
              'remark': '明细-$i',
              'destination': 'WAREHOUSE',
              if (i == 2) 'fqcRecoveryAuthorizationId': 'recovery-1',
            },
        ],
        'materialLines': [
          {'demandId': 'demand-1', 'qtyBase': 117},
        ],
      };
      final active = {
        'id': 'supplement-1',
        'inputLineIndex': 0,
        'sourceSegmentId': 'segment-0',
        'actualQty': 130,
        'proofId': 'proof-1',
        'status': 'APPROVED',
        'segmentStatus': 'IN_PROGRESS',
      };
      final supplement = ProductionOutputSupplementView({
        ...active,
        'sourceLine': source(0),
        'originalReportQty': 100,
        'supplementQty': 30,
        'supplementSegmentStatus': 'IN_PROGRESS',
        'reportContext': snapshot,
        'inputSources': [
          for (var i = 0; i < 3; i++)
            {
              'inputLineIndex': i,
              'sourceLine': {
                ...source(i),
                if (scenario == 'wrong-source' && i == 1)
                  'executionSegmentSalesAllocationId': 'another-order',
              },
            },
        ],
        'relatedSupplements': [
          {
            ...active,
            'id': 'old-cancelled',
            'status': 'CANCELLED',
            'actualQty': 90,
          },
          active,
          if (scenario == 'duplicate-active')
            {...active, 'id': 'another-active'},
        ],
      });
      final api = _api(
        onCreate: (body) => saved = body,
        onSourceRequest: sourceRequests.add,
        responseOverride: (request) {
          if (request.path.endsWith(
            '/actual-output-supplements/supplement-1',
          )) {
            return supplement.data;
          }
          if (request.path.endsWith('/material-usage-sources')) {
            return request.queryParameters['executionSegmentId'] == 'segment-0'
                ? [
                    {
                      'sourcePlanId': 'plan-0',
                      'executionSegmentId': 'segment-0',
                      'executionSegmentCode': 'ZX-0',
                      'canOpen': true,
                      'canSettle': true,
                      'shared': false,
                    },
                  ]
                : <dynamic>[];
          }
          if (request.path.endsWith('/clearance')) {
            return [
              {
                'planId': 'plan-0',
                'demandId': 'demand-1',
                'goodsId': 'raw',
                'executionSegmentId': 'segment-0',
                'issuedQty': 200,
                'unclearedQty': 200,
                'availableToSettleQty': 200,
                'requiredQty': 100,
                'requiredForProductQty': 100,
                'requirementMode': 'LINEAR',
              },
            ];
          }
          return null;
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            departmentRepositoryProvider.overrideWithValue(
              _FakeDepartmentRepository(),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
            employeeRepositoryProvider.overrideWithValue(
              _FakeEmployeeRepository(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
            }),
          ],
          child: MaterialApp(
            home: Column(
              children: [
                const AppNotificationHost(),
                Expanded(
                  child: ProductionDailyReportEditPage(
                    initialSupplement: supplement,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        sourceRequests,
        isEmpty,
        reason: 'Own draft occupancy must not hide captured input metadata',
      );
      if (scenario == 'complete') {
        final grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
          find.byType(UtenEditableGrid<DailyGridRow>),
        );
        final products = grid.controller.rows
            .where((row) => !row.isMaterialRow)
            .toList();
        expect(products.map((row) => row.qty.text), ['130', '5', '2']);
        expect(products.map((row) => row.planId), [
          'plan-0',
          'plan-1',
          'plan-2',
        ]);
        expect(products.first.supplementProofId, 'proof-1');
        expect(products.last.fqcRecoveryAuthorizationId, 'recovery-1');
        expect(products.last.fqcRecoveryDispositionCode, 'REWORK');
        expect(products.last.hasReportQuantityLimit, isTrue);
        final material = grid.controller.rows.firstWhere(
          (row) => row.materialEditable,
        );
        expect(material.materialUsed.text, '117');
        expect(material.materialInput.manuallyEdited, isTrue);
        expect(find.textContaining('尚未保存日报'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(saved, isNotNull);
        expect(saved!['idempotencyKey'], 'captured-report-key');
        final rows = (saved!['items'] as List).cast<Map<String, dynamic>>();
        expect(rows, hasLength(3));
        expect(rows.first['qty'], 130);
        expect(rows.first['supplementProofId'], 'proof-1');
        expect(rows[1]['executionSegmentId'], 'segment-1');
        expect(rows[1]['remark'], '明细-1');
        expect(rows.last['fqcRecoveryAuthorizationId'], 'recovery-1');
        expect(saved!['materialLines'], [
          {'demandId': 'demand-1', 'qtyBase': 117.0},
        ]);
      } else {
        expect(find.textContaining('恢复申请内容未完成'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(saved, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'cancelling whole-report overflow preserves other rows and manual material use',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      Map<String, dynamic>? submitted;
      Map<String, dynamic>? previewed;
      final api = _api(
        sourceOverrides: {
          'planId': 'plan-1',
          'plannedQty': 100,
          'maxReportQty': 100,
          'allowActualOverproduction': true,
        },
        onCreate: (body) => submitted = body,
        previewResult: (body) {
          previewed = body;
          return {
            'requiresSupplements': true,
            'lines': [
              {
                'inputLineIndex': 0,
                'sourceExecutionSegmentId': 'segment-1',
                'sourceSalesAllocationId': null,
                'actualQty': 130,
                'originalReportQty': 100,
                'supplementQty': 30,
                'requiresSupplement': true,
                'fingerprint': 'batch-fingerprint',
              },
            ],
          };
        },
        responseOverride: (request) {
          if (request.path.endsWith('/material-usage-sources')) {
            return request.queryParameters['executionSegmentId'] == 'segment-1'
                ? [
                    {
                      'executionSegmentId': 'segment-1',
                      'executionSegmentCode': 'SEG-001',
                      'canOpen': true,
                      'canSettle': true,
                      'shared': false,
                    },
                  ]
                : <dynamic>[];
          }
          if (request.path.endsWith('/clearance')) {
            return [
              {
                'planId': 'plan-1',
                'demandId': 'demand-1',
                'goodsId': 'raw',
                'goodsName': '测试原料',
                'executionSegmentId': 'segment-1',
                'issuedQty': 200,
                'unclearedQty': 200,
                'availableToSettleQty': 200,
                'requiredQty': 100,
                'requiredForProductQty': 100,
                'requirementMode': 'LINEAR',
              },
            ];
          }
          return null;
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            departmentRepositoryProvider.overrideWithValue(
              _FakeDepartmentRepository(),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
            employeeRepositoryProvider.overrideWithValue(
              _FakeEmployeeRepository(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
            }),
          ],
          child: const MaterialApp(
            home: Column(
              children: [
                AppNotificationHost(),
                Expanded(
                  child: ProductionDailyReportEditPage(
                    initialExecutionSegmentId: 'segment-1',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
        find.byType(UtenEditableGrid<DailyGridRow>),
      );
      final product = grid.controller.rows.firstWhere(
        (row) => !row.isMaterialRow,
      );
      product.qty.text = '130';
      final material = grid.controller.rows.firstWhere(
        (row) => row.materialEditable,
      );
      material.materialUsed.text = '117';
      final other = product.clone()
        ..planId = 'normal-plan'
        ..planItemId = 'normal-item'
        ..executionSegmentId = 'normal-segment'
        ..qty.text = '5';
      grid.controller.addRow(other);
      grid.controller.setSelected([other], true);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(find.text('需要追加生产计划'), findsOneWidget);
      expect(find.textContaining('原工单 100.0；独立追加 30.0'), findsOneWidget);
      await tester.tap(find.text('返回原报工表'));
      await tester.pumpAndSettle();
      expect(submitted, isNull);
      expect(product.qty.text, '130');
      expect(other.qty.text, '5');
      expect(material.materialUsed.text, '117');
      final report = previewed!['report'] as Map;
      expect(report['items'], hasLength(2));
      expect(report['materialLines'], [
        {'demandId': 'demand-1', 'qtyBase': 117.0},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in [
    'legacy',
    'warehouse',
    'workshop',
    'recovery',
    'after-plan',
  ]) {
    testWidgets('actual output requires explicit server permission: $mode', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      Map<String, dynamic>? saved;
      final api = _api(
        sourceOverrides: {
          'allowActualOverproduction': mode != 'legacy',
          'maxReportQty': mode == 'after-plan' ? 0 : 10,
          if (mode == 'recovery') 'fqcRecoveryAuthorizationId': 'recovery-1',
        },
        onCreate: (payload) => saved = payload,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            departmentRepositoryProvider.overrideWithValue(
              _FakeDepartmentRepository(),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
            employeeRepositoryProvider.overrideWithValue(
              _FakeEmployeeRepository(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
            }),
          ],
          child: const MaterialApp(
            home: Column(
              children: [
                AppNotificationHost(),
                Expanded(
                  child: ProductionDailyReportEditPage(
                    initialExecutionSegmentId: 'segment-1',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
        find.byType(UtenEditableGrid<DailyGridRow>),
      );
      final row = grid.controller.rows.single;
      if (mode == 'after-plan') expect(row.qty.text, isEmpty);
      final actualQty = mode == 'after-plan' ? 1 : 11;
      row.qty.text = '$actualQty';
      if (mode == 'workshop') {
        row.destination = 'WORKSHOP';
        row.directTransfer = const ProductionDirectTransferCandidate(
          demandId: 'target-demand',
          executionSegmentId: 'parent-task',
          remainingQty: 10,
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      if (mode == 'legacy' || mode == 'recovery') {
        expect(saved, isNull);
        expect(find.textContaining('超过当前可报数量'), findsOneWidget);
      } else {
        expect(saved, isNotNull);
        final items = saved!['items'] as List;
        expect(items, hasLength(1));
        final item = items.single as Map;
        expect(item['qty'], actualQty);
        expect(item['planItemId'], 'plan-item-1');
        expect(item['executionSegmentId'], 'segment-1');
        expect(item['salesOrderItemId'], 'order-item-1');
        expect(item.containsKey('publicOutput'), isFalse);
        if (mode == 'workshop') {
          expect(item['destination'], 'WORKSHOP');
          expect(item['directTransferDemandId'], 'target-demand');
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final scenario in [
    'ready',
    'material-failure',
    'draft-failure',
    'legacy-final',
    'split-output',
    'cross-plan-source',
    'approved-proof',
    'only-approved-proof',
  ]) {
    final failMaterialRead = scenario == 'material-failure';
    final failDraftRead = scenario == 'draft-failure';
    final proofScenario = scenario.contains('approved-proof');
    testWidgets('editing draft preserves stored use: $scenario', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      Map<String, dynamic>? saved;
      final clearanceRequests = <RequestOptions>[];
      var detailUnavailable = failDraftRead;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (request.path.endsWith('/preview-report')) {
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {'requiresSupplements': false, 'lines': <dynamic>[]},
                ),
              );
              return;
            }
            if (request.path.endsWith('/clearance')) {
              clearanceRequests.add(request);
            }
            if (detailUnavailable &&
                request.method == 'GET' &&
                request.path.endsWith('/daily-reports/draft')) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            if (request.method == 'PUT' &&
                request.path.endsWith('/daily-reports/draft')) {
              saved = Map<String, dynamic>.from(request.data as Map);
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            if (failMaterialRead && request.path.endsWith('/clearance')) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionError,
                ),
              );
              return;
            }
            dynamic data = <dynamic>[];
            if (request.path.endsWith('/daily-reports/draft')) {
              data = {
                'id': 'draft',
                'status': 0,
                'rowVersion': 1,
                'makerId': 'employee-1',
                'departmentId': 'workshop',
                'workshopName': '装配第一车间',
                'workerIds': ['employee-1'],
                'surplusReturnRequested': failMaterialRead,
                'items': [
                  {
                    'id': 'line',
                    'goodsId': 'goods-1',
                    'planId': 'plan-1',
                    'planItemId': 'plan-item-1',
                    'planNo': 'SJ-001',
                    'executionSegmentId': 'segment-1',
                    'unitId': 'unit-1',
                    'unitRate': 1,
                    'qty': scenario == 'split-output' ? 3 : 5,
                    'isFinal': scenario == 'legacy-final',
                    'remainingPlanQty': 20,
                    if (scenario == 'split-output') ...{
                      'outputBatchId': 'batch-1',
                      'outputBatchQty': 5,
                      'weight': 1.2,
                      'allowActualOverproduction': true,
                      'outputKind': 'PLANNED',
                    },
                  },
                  if (scenario == 'split-output')
                    {
                      'id': 'public-line',
                      'goodsId': 'goods-1',
                      'planId': 'plan-1',
                      'planItemId': 'plan-item-1',
                      'planNo': 'SJ-001',
                      'executionSegmentId': 'segment-1',
                      'unitId': 'unit-1',
                      'unitRate': 1,
                      'qty': 2,
                      'outputBatchId': 'batch-1',
                      'outputBatchQty': 5,
                      'weight': 0.8,
                      'allowActualOverproduction': true,
                      'publicOutput': true,
                      'actualSurplus': true,
                      'outputKind': 'ACTUAL_SURPLUS',
                    },
                ],
                'materialUsages': [
                  {
                    'demandId': 'demand-1',
                    'qtyBase': 7,
                    'planId': 'plan-1',
                    'materialExecutionSegmentId':
                        scenario == 'cross-plan-source'
                        ? 'original-segment'
                        : 'segment-1',
                  },
                ],
              };
              if (proofScenario) {
                final total = scenario == 'only-approved-proof' ? 25 : 130;
                Map<String, dynamic> proofItem(bool original) => {
                  'id': original ? 'original-line' : 'supplement-line',
                  'goodsId': 'goods-1',
                  'planId': original ? 'plan-1' : 'supplement-plan',
                  'planItemId': original ? 'plan-item-1' : 'supplement-item',
                  'planNo': original ? 'SJ-001' : 'SJ-SUPPLEMENT',
                  'executionSegmentId': original
                      ? 'segment-1'
                      : 'supplement-segment',
                  'unitId': 'unit-1',
                  'unitRate': 1,
                  'qty': original ? 100 : total - (total == 130 ? 100 : 0),
                  'outputBatchId': 'proof-batch',
                  'outputBatchQty': total,
                  'supplementProofId': 'proof-1',
                  'publicOutput': !original,
                  'outputSourcePlanId': 'plan-1',
                  'outputSourcePlanItemId': 'plan-item-1',
                  'outputSourceExecutionSegmentId': 'segment-1',
                };
                (data as Map)['items'] = [
                  if (total == 130) proofItem(true),
                  proofItem(false),
                  {
                    'id': 'normal-line',
                    'goodsId': 'goods-1',
                    'planId': 'normal-plan',
                    'planItemId': 'normal-item',
                    'planNo': 'SJ-NORMAL',
                    'executionSegmentId': 'normal-segment',
                    'unitId': 'unit-1',
                    'unitRate': 1,
                    'qty': 5,
                  },
                ];
              }
            } else if (request.path.endsWith('/material-usage-sources')) {
              data = [
                {
                  'executionSegmentId': scenario == 'cross-plan-source'
                      ? 'original-segment'
                      : 'segment-1',
                  if (scenario == 'cross-plan-source')
                    'sourcePlanId': 'original-plan',
                  'executionSegmentCode': 'SEG-001',
                  'canOpen': true,
                  'canSettle': true,
                  'shared': false,
                },
              ];
            } else if (request.path.endsWith('/clearance')) {
              data = [
                {
                  'planId': scenario == 'cross-plan-source'
                      ? 'original-plan'
                      : 'plan-1',
                  'demandId': 'demand-1',
                  'goodsId': 'raw',
                  'goodsName': '测试原料',
                  'executionSegmentId': scenario == 'cross-plan-source'
                      ? 'original-segment'
                      : 'segment-1',
                  'issuedQty': 10,
                  'unclearedQty': 10,
                  'availableToSettleQty': 10,
                  'requiredQty': 10,
                  'requiredForProductQty': 10,
                  'requirementMode': 'LINEAR',
                },
              ];
            } else if (request.path.endsWith('/direct-transfers/candidates')) {
              data = {'candidates': <dynamic>[]};
            }
            handler.resolve(
              Response(requestOptions: request, statusCode: 200, data: data),
            );
          },
        ),
      );
      final api = ApiClient(dio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            departmentRepositoryProvider.overrideWithValue(
              _FakeDepartmentRepository(),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
            employeeRepositoryProvider.overrideWithValue(
              _FakeEmployeeRepository(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportEdit,
            }),
            documentScopeCapabilityProvider(
              DocumentDataScope.productionPlan,
            ).overrideWith(
              (ref) async => const DocumentScopeCapability(
                scope: 'production_plan',
                writeAll: true,
                writableOwnerIds: {},
              ),
            ),
          ],
          child: const MaterialApp(
            home: Column(
              children: [
                AppNotificationHost(),
                Expanded(child: ProductionDailyReportEditPage(id: 'draft')),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (failDraftRead) {
        expect(find.byType(UtenEditableGrid<DailyGridRow>), findsNothing);
        expect(find.byKey(const ValueKey('uten-edit-save')), findsNothing);
        expect(saved, isNull);
        detailUnavailable = false;
        await tester.tap(find.text('重新读取草稿'));
        await tester.pumpAndSettle();
      }
      if (scenario == 'legacy-final') {
        await tester.tap(find.text('改为普通报工'));
        await tester.pumpAndSettle();
        expect(find.text('改为普通报工'), findsNothing);
      }
      if (!failMaterialRead) {
        if (scenario == 'cross-plan-source') {
          expect(clearanceRequests, isNotEmpty);
          expect(
            clearanceRequests.every(
              (request) => request.path.contains('/original-plan/'),
            ),
            isTrue,
          );
          expect(
            clearanceRequests.every(
              (request) =>
                  request.queryParameters['executionSegmentId'] ==
                  'original-segment',
            ),
            isTrue,
          );
        }
        expect(
          find.text('测试原料'),
          proofScenario ? findsNWidgets(2) : findsOneWidget,
        );
        var grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
          find.byType(UtenEditableGrid<DailyGridRow>),
        );
        final first = grid.controller.rows.firstWhere(
          (row) => !row.isMaterialRow,
        );
        if (scenario == 'split-output') {
          expect(
            grid.controller.rows.where((row) => !row.isMaterialRow),
            hasLength(1),
          );
          expect(double.parse(first.qty.text), 5);
          expect(double.parse(first.weight.text), 2);
        }
        if (proofScenario) {
          expect(
            grid.controller.rows.where((row) => !row.isMaterialRow),
            hasLength(2),
          );
          expect(
            double.parse(first.qty.text),
            scenario == 'only-approved-proof' ? 25 : 130,
          );
          expect(first.supplementProofId, 'proof-1');
          expect(first.executionSegmentId, 'segment-1');
          expect(first.planItemId, 'plan-item-1');
          expect(first.hasFixedSupplement, isTrue);
          expect(
            tester
                .widget<TextField>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is TextField &&
                        identical(widget.controller, first.qty),
                  ),
                )
                .readOnly,
            isTrue,
          );
          first.remark.text = '核对后保留原批次';
          grid.controller.rows
                  .firstWhere((row) => row.materialEditable)
                  .materialUsed
                  .text =
              '8';
          grid.controller.rows
                  .firstWhere((row) => row.planItemId == 'normal-item')
                  .remark
                  .text =
              '其他行仍保留';
        } else {
          final copy = first.clone();
          grid.controller.addRow(copy);
          await tester.pumpAndSettle();
          final material = grid.controller.rows.firstWhere(
            (row) => row.materialEditable,
          );
          material.materialUsed.text = '8';
          copy.qty.text = '6';
          await tester.pumpAndSettle();
          expect(material.materialUsed.text, '8');
          expect(material.materialUsageAutofilled.value, isFalse);
          grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
            find.byType(UtenEditableGrid<DailyGridRow>),
          );
          grid.onDeleteRow!(first, 0);
          await tester.pumpAndSettle();
          final remaining = grid.controller.rows
              .where((row) => row.materialEditable)
              .toList();
          expect(remaining, hasLength(1));
          expect(remaining.single.materialParent, copy);
          expect(remaining.single.materialUsed.text, '8');
        }
      }
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      if (proofScenario) {
        final items = (saved!['items'] as List).cast<Map<String, dynamic>>();
        expect(items, hasLength(2));
        expect(
          items.first['qty'],
          scenario == 'only-approved-proof' ? 25 : 130,
        );
        expect(items.first['supplementProofId'], 'proof-1');
        expect(items.first['executionSegmentId'], 'segment-1');
        expect(items.first['planItemId'], 'plan-item-1');
        expect(items.first['remark'], '核对后保留原批次');
        expect(items.last['qty'], 5);
        expect(items.last['remark'], '其他行仍保留');
      }
      expect(saved!['materialLines'], [
        {'demandId': 'demand-1', 'qtyBase': failMaterialRead ? 7 : 8},
      ]);
      expect(saved!['surplusReturnRequested'] == true, failMaterialRead);
      expect(
        (saved!['items'] as List).every(
          (item) => (item as Map)['isFinal'] != true,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'production workforce tree keeps the center and production branch only',
    () async {
      final container = ProviderContainer(
        overrides: [
          departmentRepositoryProvider.overrideWithValue(
            _FakeDepartmentRepository(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final scope = await container.read(
        productionWorkforceTreeProvider.future,
      );

      expect(scope.tree.single.name, '制造与研发管理中心');
      expect(scope.tree.single.children.single.code, 'DEPT_PROD');
      expect(
        scope.tree.single.children.single.children.single.code,
        'WS_ASSEMBLY',
      );
      expect(scope.productionDepartmentId, 'production');
      expect(scope.initiallyExpandedIds, containsAll(['center', 'production']));
    },
  );

  testWidgets(
    'exact execution segment applies its only reportable source without reopening picker',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _api();
      final employees = _FakeEmployeeRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            departmentRepositoryProvider.overrideWithValue(
              _FakeDepartmentRepository(),
            ),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
            employeeRepositoryProvider.overrideWithValue(employees),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            home: ProductionDailyReportEditPage(
              initialExecutionSegmentId: 'segment-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('选择报工子任务'), findsNothing);
      expect(find.text('成品灯'), findsOneWidget);
      expect(find.text('SEG-001'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);

      await tester.tap(find.byType(UtenEmployeeMultiPicker));
      await tester.pumpAndSettle();
      await tester.tap(find.text('张三(UT001)'));
      await tester.tap(find.text('李四(UT002)'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();

      expect(find.text('张三(UT001)'), findsOneWidget);
      expect(find.text('李四(UT002)'), findsOneWidget);
      expect(employees.lastDepartmentId, 'workshop');
      expect(employees.lastStatuses, {'active', 'probation'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('新建日报勾选口径：来源行自动勾选，没勾行时保存置灰并说明原因', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _api();
    final employees = _FakeEmployeeRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          departmentRepositoryProvider.overrideWithValue(
            _FakeDepartmentRepository(),
          ),
          masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
          productionDailyReportRepositoryProvider.overrideWithValue(
            ProductionDailyReportRepository(api),
          ),
          employeeRepositoryProvider.overrideWithValue(employees),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          home: Column(
            children: [
              AppNotificationHost(),
              Expanded(
                child: ProductionDailyReportEditPage(
                  initialExecutionSegmentId: 'segment-1',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('成品灯'), findsOneWidget);

    final save = find.byKey(const ValueKey('uten-edit-save'));
    UtenButton saveButton() => tester.widget<UtenButton>(save);
    // 深链来源已应用到行 → 自动勾选（2026-09-18 勾选口径），保存可点。
    expect(saveButton().onPressed, isNotNull);
    // 取消行勾选（行框树序在表头框之前）→ 保存置灰，灰态点击说明原因。
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(saveButton().onPressed, isNull);
    await tester.tap(save);
    await tester.pump();
    expect(find.textContaining('请先勾选要报工的明细行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reopening the same task uses each latest partial-report remainder',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final authoritativeSource = <String, dynamic>{
        'plannedQty': 2000,
        'executionSegmentSalesAllocationId': 'allocation-1',
      };
      final sourceRequests = <RequestOptions>[];
      final api = _api(
        sourceOverrides: authoritativeSource,
        onSourceRequest: sourceRequests.add,
      );
      var produced = 0;
      for (final batchQty in [500, 700, 800]) {
        final remaining = 2000 - produced;
        authoritativeSource.addAll({
          'producedQty': produced,
          'remainingPlanQty': remaining,
          'maxReportQty': remaining,
        });
        // Each server snapshot represents another visit from the workshop task
        // after the previous batch was approved; local quantity edits are not
        // carried into this new report.
        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey(produced),
            overrides: [
              apiClientProvider.overrideWithValue(api),
              departmentRepositoryProvider.overrideWithValue(
                _FakeDepartmentRepository(),
              ),
              masterNameServiceProvider.overrideWithValue(
                MasterNameService(api),
              ),
              productionDailyReportRepositoryProvider.overrideWithValue(
                ProductionDailyReportRepository(api),
              ),
              employeeRepositoryProvider.overrideWithValue(
                _FakeEmployeeRepository(),
              ),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: const MaterialApp(
              home: ProductionDailyReportEditPage(
                initialExecutionSegmentId: 'segment-1',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
          find.byType(UtenEditableGrid<DailyGridRow>),
        );
        final row = grid.controller.rows.single;
        expect(row.qty.text, '$remaining');
        expect(row.maxReportQty, remaining);
        expect(row.remainingPlanQty, remaining);
        expect(row.executionSegmentId, 'segment-1');
        expect(row.executionSegmentSalesAllocationId, 'allocation-1');
        expect(row.salesOrderItemId, 'order-item-1');
        expect(row.goods?.id, 'goods-1');
        expect(find.text('成品灯'), findsOneWidget);
        expect(find.text('装配第一车间'), findsOneWidget);
        expect(find.text('选择报工子任务'), findsNothing);
        row.qty.text = '$batchQty';
        await tester.pumpAndSettle();
        expect(
          row.qty.text,
          '$batchQty',
          reason: 'keep the explicit partial quantity',
        );
        expect(row.isFinal, isFalse);
        expect(tester.takeException(), isNull);
        produced += batchQty;
      }
      expect(sourceRequests, hasLength(3));
      expect(
        sourceRequests.every(
          (request) =>
              request.queryParameters['executionSegmentId'] == 'segment-1',
        ),
        isTrue,
      );
    },
  );

  for (final availableQty in [1000, 750]) {
    testWidgets(
      'partially reported task prefills unallocated goods and available remainder $availableQty',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final sourceRequests = <RequestOptions>[];
        Map<String, dynamic>? saved;
        final api = _api(
          sourceOverrides: {
            'plannedQty': 2000,
            'producedQty': 1000,
            'remainingPlanQty': availableQty,
            'maxReportQty': availableQty,
            'executionSegmentSalesAllocationId': null,
            'orderItemId': null,
            'orderNo': null,
            'orderQty': null,
            'clientName': null,
          },
          onSourceRequest: sourceRequests.add,
          onCreate: (body) => saved = body,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              departmentRepositoryProvider.overrideWithValue(
                _FakeDepartmentRepository(),
              ),
              masterNameServiceProvider.overrideWithValue(
                MasterNameService(api),
              ),
              productionDailyReportRepositoryProvider.overrideWithValue(
                ProductionDailyReportRepository(api),
              ),
              employeeRepositoryProvider.overrideWithValue(
                _FakeEmployeeRepository(),
              ),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: const MaterialApp(
              home: ProductionDailyReportEditPage(
                initialExecutionSegmentId: 'segment-1',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(sourceRequests, hasLength(1));
        expect(sourceRequests.single.queryParameters, {
          'page': 1,
          'size': 2,
          'executionSegmentId': 'segment-1',
        });
        final grid = tester.widget<UtenEditableGrid<DailyGridRow>>(
          find.byType(UtenEditableGrid<DailyGridRow>),
        );
        final row = grid.controller.rows.single;
        expect(row.executionSegmentId, 'segment-1');
        expect(row.executionSegmentSalesAllocationId, isNull);
        expect(row.salesOrderItemId, isNull);
        expect(row.salesOrderNo, isNull);
        expect(row.clientName, isNull);
        expect(row.goods?.id, 'goods-1');
        expect(row.goods?.code, 'P-001');
        expect(row.goods?.name, '成品灯');
        expect(row.qty.text, '$availableQty');
        expect(row.maxReportQty, availableQty);
        // An outstanding draft may reserve 250, but only approved reports
        // reduce the task's remaining completion quantity.
        expect(row.remainingPlanQty, 1000);
        expect(row.isFinal, isFalse);
        expect(find.text('选择报工子任务'), findsNothing);
        expect(find.text('成品灯'), findsOneWidget);
        expect(find.text('装配第一车间'), findsOneWidget);
        expect(
          tester
              .widget<UtenButton>(find.byKey(const ValueKey('uten-edit-save')))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(saved, isNotNull);
        expect(saved!['departmentId'], 'workshop');
        expect(saved!['workshopName'], '装配第一车间');
        final items = saved!['items'] as List;
        expect(items, hasLength(1));
        expect(items.single, {
          'goodsId': 'goods-1',
          'qty': availableQty,
          'unitId': 'unit-1',
          'unitRate': 1,
          'planItemId': 'plan-item-1',
          'executionSegmentId': 'segment-1',
          'planNo': 'SJ-001',
        });
        expect(tester.takeException(), isNull);
      },
    );
  }
}

ApiClient _api({
  Map<String, dynamic> sourceOverrides = const {},
  void Function(RequestOptions)? onSourceRequest,
  void Function(Map<String, dynamic>)? onCreate,
  Map<String, dynamic> Function(Map<String, dynamic>)? previewResult,
  Object? Function(RequestOptions)? responseOverride,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        if (request.path.endsWith('/preview-report')) {
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data:
                  previewResult?.call(
                    Map<String, dynamic>.from(request.data as Map),
                  ) ??
                  {'requiresSupplements': false, 'lines': <dynamic>[]},
            ),
          );
          return;
        }
        final override = responseOverride?.call(request);
        if (override != null) {
          handler.resolve(
            Response(requestOptions: request, statusCode: 200, data: override),
          );
          return;
        }
        if (request.path.endsWith('/reportable-plan-lines')) {
          onSourceRequest?.call(request);
        }
        if (request.method == 'POST' &&
            request.path.endsWith('/daily-reports') &&
            onCreate != null) {
          onCreate(Map<String, dynamic>.from(request.data as Map));
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            ),
          );
          return;
        }
        final data =
            request.path.endsWith(
              '/production/daily-reports/reportable-plan-lines',
            )
            ? {
                'items': [
                  {
                    'planItemId': 'plan-item-1',
                    'executionSegmentId': 'segment-1',
                    'executionSegmentCode': 'SEG-001',
                    'executionSegmentStatus': 'IN_PROGRESS',
                    'executionSegmentVersion': 3,
                    'orderItemId': 'order-item-1',
                    'planNo': 'SJ-001',
                    'goodsId': 'goods-1',
                    'goodsCode': 'P-001',
                    'goodsName': '成品灯',
                    'unitId': 'unit-1',
                    'unitRate': 1,
                    'maxReportQty': 10,
                    'orderNo': 'SO-001',
                    'departmentId': 'workshop',
                    'workshopName': '装配第一车间',
                    ...sourceOverrides,
                  },
                ],
                'page': 1,
                'size': 2,
                'total': 1,
                'totalPages': 1,
              }
            : <dynamic>[];
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

class _FakeDepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => [
    DepartmentNode(
      id: 'center',
      code: 'MFG_CENTER',
      name: '制造与研发管理中心',
      level: '管理中心',
      children: [
        DepartmentNode(
          id: 'production',
          code: 'DEPT_PROD',
          name: '生产部',
          level: '一级部门',
          parentId: 'center',
          children: [
            DepartmentNode(
              id: 'workshop',
              code: 'WS_ASSEMBLY',
              name: '装配第一车间',
              level: '二级班组',
              parentId: 'production',
              children: const [],
            ),
          ],
        ),
        DepartmentNode(
          id: 'quality',
          code: 'DEPT_QA',
          name: '品质管理部',
          level: '一级部门',
          parentId: 'center',
          children: const [],
        ),
      ],
    ),
  ];

  @override
  Future<DepartmentInfo> detail(String id) => throw UnimplementedError();

  @override
  Future<WorkforceOverview> workforceOverview(String id) =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEmployeeRepository implements EmployeeRepository {
  String? lastDepartmentId;
  Set<String>? lastStatuses;

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) async {
    lastDepartmentId = departmentId;
    lastStatuses = statuses;
    return const PagedResult(
      items: [
        EmployeeSummary(
          id: 'employee-1',
          code: 'UT001',
          fullName: '张三',
          departmentId: 'workshop',
          departmentName: '装配第一车间',
        ),
        EmployeeSummary(
          id: 'employee-2',
          code: 'UT002',
          fullName: '李四',
          departmentId: 'workshop',
          departmentName: '装配第一车间',
        ),
      ],
      page: 1,
      size: 100,
      total: 2,
      totalPages: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
