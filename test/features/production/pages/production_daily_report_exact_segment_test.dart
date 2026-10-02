import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';
import 'package:uten_imp/features/production/models/production_daily_report_create_request.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_create_recovery_page.dart';
import '../../../support/native_detail_reader_overrides.dart';
import '../../../support/controlled_attachment_pipeline.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_edit_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/repositories/production_actual_output_supplement_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/platform_table_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';

part 'production_daily_report_draft_identity_cases.dart';
part 'production_daily_report_create_recovery_cases.dart';
part 'production_daily_report_attachment_late_ack_cases.dart';

class _ExactSegmentSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'report-user', code: 'E001', name: '测试员工'),
  );
}

class _ExactSegmentSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

void main() {
  registerDailyReportDraftIdentityTests();
  registerDailyReportCreateRecoveryTests();
  registerDailyReportLateAttachmentAckTests();
  for (final attachmentMode in ['none', 'upload', 'retry']) {
    testWidgets(
      'workshop save returns saved draft for review, never approves: attachments=$attachmentMode',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1440, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        var creates = 0;
        var approvals = 0;
        String? savedId;
        Map<String, dynamic>? submittedBody;
        var receiptReads = 0;
        final api = _api(
          responseOverride: (request) {
            if (request.path.endsWith('/approve')) approvals++;
            if (request.method == 'POST' &&
                request.path.endsWith('/daily-reports')) {
              creates++;
              submittedBody = Map<String, dynamic>.from(request.data as Map);
              return {
                'id': 'saved-draft',
                'makerId': 'employee-1',
                'billNo': 'SR-DRAFT',
                'status': 0,
                'items': <dynamic>[],
              };
            }
            if (request.path.endsWith('/daily-reports/create-receipt')) {
              receiptReads++;
              expect(request.data, submittedBody);
              return _createProofBody(
                Map<String, dynamic>.from(request.data as Map),
                'saved-draft',
              );
            }
            if (request.method == 'GET' &&
                request.path.endsWith('/daily-reports/saved-draft')) {
              return {
                'id': 'saved-draft',
                'billNo': 'SR-DRAFT',
                'status': 0,
                'makerId': 'employee-1',
                'items': <dynamic>[],
              };
            }
            return null;
          },
        );
        final attachments = _ReportSaveAttachments(
          api,
          failFirst: attachmentMode == 'retry',
        );
        late final GoRouter router;
        router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    savedId = await context.push<String>(
                      '/production/daily-reports/new',
                    );
                    if (context.mounted && savedId != null) {
                      await context.push<void>('/review/$savedId');
                    }
                  },
                  child: const Text('开始报工'),
                ),
              ),
            ),
            GoRoute(
              path: '/production/daily-reports/new',
              builder: (_, _) => const ProductionDailyReportEditPage(
                initialExecutionSegmentId: 'segment-1',
                returnToWorkshopTasks: true,
              ),
            ),
            GoRoute(
              path: '/review/:id',
              builder: (_, state) =>
                  Scaffold(body: Text('待审核 ${state.pathParameters['id']}')),
            ),
          ],
        );
        addTearDown(router.dispose);
        final container = ProviderContainer(
          overrides: [
            ...nativeDetailReaderOverrides(),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            apiClientProvider.overrideWithValue(api),
            attachmentServiceProvider.overrideWithValue(attachments),
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
              Perm.productionDailyReportView,
            }),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_ExactSegmentSession.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'report-user'),
            ),
            sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
              Perm.productionDailyReportView,
              Perm.productionDailyReportEdit,
              Perm.attachmentUpload,
            }),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('开始报工'));
        await tester.pumpAndSettle();
        if (attachmentMode != 'none') {
          tester
              .widgetList<BusinessAttachmentSection>(
                find.byType(BusinessAttachmentSection),
              )
              .firstWhere((section) => section.isDraft)
              .draftController!
              .restoreDraft({
                'items': [
                  {
                    'localUploadId': 'fresh-report-fixture',
                    'uploadTrackingVersion': 1,
                    'name': 'report.txt',
                    'contentType': 'text/plain',
                    'bytes': 'AQID',
                  },
                ],
              });
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        if (attachmentMode == 'retry') {
          expect(savedId, isNull);
          expect(creates, 1);
          expect(find.byType(ProductionDailyReportEditPage), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
          await tester.pumpAndSettle();
        }
        expect(savedId, 'saved-draft');
        expect(find.text('待审核 saved-draft'), findsOneWidget);
        expect(creates, 1);
        expect(receiptReads, 1);
        expect(approvals, 0);
        expect(
          attachments.attempts,
          attachmentMode == 'none' ? 0 : (attachmentMode == 'retry' ? 2 : 1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      },
    );
  }

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
              if (i == 1) 'defectQty': 1.5,
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
              Perm.productionDailyReportView,
            }),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_ExactSegmentSession.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'report-user'),
            ),
            sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
              Perm.productionDailyReportView,
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
            .where((row) => !row.isSubRow)
            .toList();
        expect(products.map((row) => row.qty.text), ['130', '5', '2']);
        expect(products.map((row) => row.defectQty.text), ['', '1.5', '']);
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
        expect(rows[1]['defectQty'], 1.5);
        expect(rows.first.containsKey('defectQty'), isFalse);
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
              Perm.productionDailyReportView,
            }),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_ExactSegmentSession.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'report-user'),
            ),
            sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
              Perm.productionDailyReportView,
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
      final product = grid.controller.rows.firstWhere((row) => !row.isSubRow);
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
          if (mode == 'workshop') 'planId': 'plan-1',
          'allowActualOverproduction': mode != 'legacy',
          'maxReportQty': mode == 'after-plan' ? 0 : 10,
          if (mode == 'recovery') 'fqcRecoveryAuthorizationId': 'recovery-1',
        },
        onCreate: (payload) => saved = payload,
        responseOverride: mode == 'workshop'
            ? (request) => request.path.endsWith('/direct-transfers/candidates')
                  ? const {
                      'candidates': [
                        {
                          'demandId': 'target-demand',
                          'executionSegmentId': 'parent-task',
                          'remainingQty': 10,
                        },
                      ],
                      'receiverLimit': 30,
                    }
                  : null
            : null,
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
              Perm.productionDailyReportView,
            }),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_ExactSegmentSession.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'report-user'),
            ),
            sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
              Perm.productionDailyReportView,
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
      final row = grid.controller.rows.firstWhere((row) => !row.isSubRow);
      if (mode == 'after-plan') expect(row.qty.text, isEmpty);
      final actualQty = mode == 'after-plan' ? 1 : 11;
      row.qty.text = '$actualQty';
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
          // V736：系统按先急后缓先分满能收的上层工单(还差 10)，余下的送入仓库。
          expect(item['allocations'], [
            {'directTransferDemandId': 'target-demand', 'qty': 10.0},
            {'directTransferDemandId': null, 'qty': 1.0},
          ]);
        } else {
          expect(item.containsKey('allocations'), isFalse);
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
                    if (scenario == 'split-output') 'defectQty': 1.5,
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
                      'defectQty': 0,
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
              Perm.productionDailyReportCreate,
              Perm.productionDailyReportView,
            }),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_ExactSegmentSession.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'report-user'),
            ),
            sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
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
        final first = grid.controller.rows.firstWhere((row) => !row.isSubRow);
        if (scenario == 'split-output') {
          expect(
            grid.controller.rows.where((row) => !row.isSubRow),
            hasLength(1),
          );
          expect(double.parse(first.qty.text), 5);
          expect(double.parse(first.weight.text), 2);
          expect(first.defectQty.text, '1.5');
        }
        if (proofScenario) {
          expect(
            grid.controller.rows.where((row) => !row.isSubRow),
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
      final savedItems = (saved!['items'] as List).cast<Map<String, dynamic>>();
      if (scenario == 'split-output') {
        // 复制行带着整次报工的不良数，良品数按用户改后的 6 提交。
        expect(savedItems.single['qty'], 6);
        expect(savedItems.single['defectQty'], 1.5);
      } else {
        expect(
          savedItems.every((item) => !item.containsKey('defectQty')),
          isTrue,
        );
      }
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
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
              Perm.productionDailyReportView,
            }),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_ExactSegmentSession.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'report-user'),
            ),
            sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
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

  // 2026-09-27 用户口径「表头右键菜单全站统一都要有」——生产车间提交报表
  // （本页）是点名缺菜单的例子。默认翻转（UtenEditableGrid.showColumnSettings
  // 默认 true）后：右击表头弹固定/移动/隐藏菜单；必填列（完工申报量）隐藏锁定。
  testWidgets('去向分配：先急后缓逐个分满，改数量后余量下移，送入仓库只留一条，提交体逐条带上', (tester) async {
    Map<String, dynamic>? saved;
    final grid = await _pumpAllocationPage(
      tester,
      onCreate: (payload) => saved = payload,
    );
    List<(String?, String, bool)> allocations() => [
      for (final row in grid.rows)
        if (row.isAllocationRow)
          (
            row.allocationDemandId,
            row.allocationQty.text,
            row.allocationAutofilled.value,
          ),
    ];
    final product = grid.rows.firstWhere((row) => !row.isSubRow);
    expect(product.qty.text, '10');
    // 先急后缓逐个分满：A 还差 6、B 还差 3，剩下 1 送入仓库；都是系统建议(黄框)。
    expect(allocations(), [
      ('A', '6', true),
      ('B', '3', true),
      (null, '1', true),
    ]);
    expect(find.text('转下一道工序 2 个工单 9 · 送入仓库 1'), findsOneWidget);

    // 把给 A 的改成 2：它和上面的条目算工人定的，下面按余量重排——B 仍 3，送入仓库 5。
    final first = product.allocationRows.first;
    final qtyField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.controller == first.allocationQty,
    );
    await tester.enterText(qtyField, '2');
    await tester.pumpAndSettle();
    expect(allocations(), [
      ('A', '2', false),
      ('B', '3', true),
      (null, '5', true),
    ]);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // 完工申报量改小到 4：工人定的 A=2 保留，B 只剩 2，没有送入仓库。
    product.qty.text = '4';
    await tester.pumpAndSettle();
    expect(allocations(), [('A', '2', false), ('B', '2', true)]);
    // 改回 10：余量重新排出来，送入仓库只有一条。
    product.qty.text = '10';
    await tester.pumpAndSettle();
    expect(allocations(), [
      ('A', '2', false),
      ('B', '3', true),
      (null, '5', true),
    ]);

    // 把 B 那条改成送入仓库：与下面的送入仓库合并成一条。
    final second = product.allocationRows[1];
    await tester.tap(
      find.byKey(
        ValueKey('daily-allocation-destination-${identityHashCode(second)}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ZX-C · 上层工单 ZX-C 在二车间，跨车间必须送入仓库'), findsOneWidget);
    await tester.tap(find.text('送入仓库').last);
    await tester.pumpAndSettle();
    expect(allocations(), [('A', '2', false), (null, '8', false)]);

    // 逐键改完工申报量会经过 1：工人定的送入仓库那条被压到 0 只是先藏起来，改回 10 原样回来。
    final warehouse = product.allocationRows[1];
    expect(
      warehouse.allocationRequested,
      3,
      reason: '工人要的是从 B 改过来的 3；顺带接下的余量 5 每次重排重新分，不算工人要的',
    );
    product.qty.text = '1';
    await tester.pumpAndSettle();
    expect(allocations(), [('A', '1', false)]);
    expect(product.allocationRows, contains(warehouse));
    expect(outputAllocationBody(product), [
      {'directTransferDemandId': 'A', 'qty': 1.0},
    ], reason: '藏起来的条目不提交');
    product.qty.text = '10';
    await tester.pumpAndSettle();
    expect(allocations(), [('A', '2', false), (null, '8', false)]);
    expect(product.allocationRows[1], same(warehouse));

    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final item = (saved!['items'] as List).single as Map;
    expect(item['qty'], 10);
    expect(item['allocations'], [
      {'directTransferDemandId': 'A', 'qty': 2.0},
      {'directTransferDemandId': null, 'qty': 8.0},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('去向分配：粘贴的行与改勾选都按当前余量重排', (tester) async {
    final grid = await _pumpAllocationPage(tester);
    List<(String?, String, bool)> allocationsOf(DailyGridRow product) => [
      for (final row in grid.rows)
        if (row.allocationParent == product)
          (
            row.allocationDemandId,
            row.allocationQty.text,
            row.allocationAutofilled.value,
          ),
    ];
    final original = grid.rows.firstWhere((row) => !row.isSubRow);
    expect(allocationsOf(original), [
      ('A', '6', true),
      ('B', '3', true),
      (null, '1', true),
    ]);

    grid.copySelected((row) => row.clone());
    grid.paste((row) => row.clone());
    await tester.pumpAndSettle();
    final pasted = grid.rows.where((row) => !row.isSubRow).last;
    expect(pasted, isNot(same(original)));
    // 同一来源的 A、B 已被勾选的原行分满：粘贴行(未勾选)只能送入仓库，但要有去向，不能空着。
    expect(allocationsOf(pasted), [(null, '10', true)]);

    // 改勾选：勾选行先占上层工单的「还差多少」。
    grid.setSelected([original], false);
    grid.setSelected([pasted], true);
    await tester.pumpAndSettle();
    expect(allocationsOf(pasted), [
      ('A', '6', true),
      ('B', '3', true),
      (null, '1', true),
    ]);
    expect(allocationsOf(original), [(null, '10', true)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('去向分配：转给工单候选读不到时自动重读一次，仍读不到就不让提交', (tester) async {
    Map<String, dynamic>? saved;
    late _FlakyCandidatesRepository repository;
    final grid = await _pumpAllocationPage(
      tester,
      onCreate: (payload) => saved = payload,
      materialRepository: (api) => repository = _FlakyCandidatesRepository(api),
    );
    final product = grid.rows.firstWhere((row) => !row.isSubRow);
    expect(product.directTransferLoadFailed, isTrue);
    expect(find.text('转给工单候选读取失败，请刷新后重试'), findsOneWidget);
    final save = find.byKey(const ValueKey('uten-edit-save'));

    final before = repository.calls;
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(repository.calls, before + 1, reason: '提交前自动重读一次');
    expect(find.textContaining('第 1 行：转给工单候选读取失败，请刷新后重试'), findsOneWidget);
    expect(saved, isNull, reason: '读不到候选不能当成整行送入仓库提交');

    // 重读成功：去向按先急后缓重新分配，先让人核对，这一次不提交。
    repository.failing = false;
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('转给工单候选已重新读到'), findsOneWidget);
    expect(saved, isNull);
    expect(product.directTransferLoadFailed, isFalse);
    expect(
      product.allocationRows.map(
        (row) => (row.allocationDemandId, row.allocationQty.text),
      ),
      [('A', '6'), ('B', '3'), (null, '1')],
    );

    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    final item = (saved!['items'] as List).single as Map;
    expect(item['allocations'], [
      {'directTransferDemandId': 'A', 'qty': 6.0},
      {'directTransferDemandId': 'B', 'qty': 3.0},
      {'directTransferDemandId': null, 'qty': 1.0},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('报工表明头右键菜单：弹菜单、隐藏列、移动换位、必填列锁定', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _api();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    Future<void> rightClick(Finder finder) async {
      final gesture = await tester.startGesture(
        tester.getCenter(finder.hitTestable().first),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await tester.pump();
    }

    double dxOf(Finder f) =>
        (f.hitTestable().first.evaluate().first.renderObject as RenderBox)
            .localToGlobal(Offset.zero)
            .dx;

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
            Perm.productionDailyReportView,
          }),
          formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
          sessionProvider.overrideWith(_ExactSegmentSession.new),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'report-user'),
          ),
          sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
          apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
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

    // 右击「编号」表头：六条菜单条目齐全（编号列有 textOf → 可固定）。
    await rightClick(find.text('编号'));
    expect(find.text('固定到左侧'), findsOneWidget);
    expect(find.text('向左移一格'), findsOneWidget);
    expect(find.text('向右移一格'), findsOneWidget);
    expect(find.text('放到最前'), findsOneWidget);
    expect(find.text('放到最后'), findsOneWidget);
    expect(find.text('隐藏此列'), findsOneWidget);

    // 隐藏「编号」列：表头与表体（P-001）一起消失。
    await tester.tap(find.text('隐藏此列'));
    await tester.pumpAndSettle();
    expect(find.text('编号'), findsNothing);
    expect(find.text('P-001'), findsNothing);

    // 移动换位：「颜色」放到最前 → 排到「单位」之前。
    await rightClick(find.text('颜色'));
    await tester.tap(find.text('放到最前'));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('颜色')), lessThan(dxOf(find.text('单位'))));

    // 固定：「单位」固定到左侧 → 排到「颜色」之前。
    await rightClick(find.text('单位'));
    await tester.tap(find.text('固定到左侧'));
    await tester.pumpAndSettle();
    expect(dxOf(find.text('单位')), lessThan(dxOf(find.text('颜色'))));
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);

    // 必填列锁定：「完工申报量」的隐藏入口置灰（必填项不允许从界面消失；
    // 必填表头带红 * 后缀，用包含匹配）。
    await rightClick(find.textContaining('完工申报量'));
    final hideInk = find.ancestor(
      of: find.text('隐藏此列'),
      matching: find.byType(InkWell),
    );
    expect((hideInk.evaluate().single.widget as InkWell).onTap, isNull);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

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
          currentPermissionsProvider.overrideWithValue({
            Perm.productionDailyReportCreate,
            Perm.productionDailyReportView,
          }),
          formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
          sessionProvider.overrideWith(_ExactSegmentSession.new),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'report-user'),
          ),
          sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
          apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
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
              currentPermissionsProvider.overrideWithValue({
                Perm.productionDailyReportCreate,
                Perm.productionDailyReportView,
              }),
              formDraftStorageProvider.overrideWithValue(
                MemoryFormDraftStorage(),
              ),
              sessionProvider.overrideWith(_ExactSegmentSession.new),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'report-user'),
              ),
              sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
              apiBaseUrlProvider.overrideWith(
                (ref) => 'https://test-server/api',
              ),
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
              currentPermissionsProvider.overrideWithValue({
                Perm.productionDailyReportCreate,
                Perm.productionDailyReportView,
              }),
              formDraftStorageProvider.overrideWithValue(
                MemoryFormDraftStorage(),
              ),
              sessionProvider.overrideWith(_ExactSegmentSession.new),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'report-user'),
              ),
              sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
              apiBaseUrlProvider.overrideWith(
                (ref) => 'https://test-server/api',
              ),
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

  // ADR-129 不良数：只记录，不改良品数；空或 0 不提交，只在已选工单的行上填。
  testWidgets('不良数：输入与保存同一口径校验，大于 0 才随行提交且良品数不变', (tester) async {
    final saved = <Map<String, dynamic>>[];
    await _pumpNewReport(tester, _api(onCreate: saved.add));
    final row = _productRows(tester).single;
    expect(find.text('不良数'), findsOneWidget);
    expect(_defectField(row), findsOneWidget);
    // 输入只接受非负数、最多 4 位小数。
    await tester.enterText(_defectField(row), '-2');
    expect(row.defectQty.text, '');
    await tester.enterText(_defectField(row), '1.23456');
    expect(row.defectQty.text, '');
    // 绕过输入框的值(例如恢复的草稿)由保存校验拦下。
    row.defectQty.text = '1.23456';
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.textContaining('第 1 行不良数请填写不小于 0、最多 4 位小数的数量'), findsOneWidget);
    await tester.enterText(_defectField(row), '2.5');
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    final item = (saved.single['items'] as List).single as Map;
    expect(item['defectQty'], 2.5);
    expect(item['qty'], 10, reason: '不良数不从完工申报量里扣');
    expect(tester.takeException(), isNull);
  });

  testWidgets('不良数填 0 与留空一样不提交', (tester) async {
    final saved = <Map<String, dynamic>>[];
    await _pumpNewReport(tester, _api(onCreate: saved.add));
    final row = _productRows(tester).single;
    await tester.enterText(_defectField(row), '0');
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    final item = (saved.single['items'] as List).single as Map;
    expect(item.containsKey('defectQty'), isFalse);
    expect(item['qty'], 10);
    expect(tester.takeException(), isNull);
  });

  test('不良数只在已选工单且完工申报量大于 0 的行上成立', () {
    final row = DailyGridRow()..defectQty.text = '2';
    addTearDown(row.dispose);
    expect(productionReportDefectIssue(row), '不良数只能记在已选择报工工单的行上');
    row.executionSegmentId = 'segment-1';
    expect(productionReportDefectIssue(row), '先填写大于 0 的完工申报量，才能记录不良数');
    row.qty.text = '0';
    expect(productionReportDefectIssue(row), '先填写大于 0 的完工申报量，才能记录不良数');
    row.qty.text = '10';
    expect(productionReportDefectIssue(row), isNull);
    expect(productionReportDefectQty(row), 2);
    for (final raw in ['', '0', '0.0000']) {
      row
        ..qty.clear()
        ..executionSegmentId = null
        ..defectQty.text = raw;
      expect(productionReportDefectIssue(row), isNull, reason: raw);
      expect(productionReportDefectQty(row), isNull, reason: raw);
    }
    row.defectQty.text = '.';
    expect(productionReportDefectIssue(row), contains('最多 4 位小数'));
    // 复制行照带不良数(良品数也照带)。
    row
      ..executionSegmentId = 'segment-1'
      ..planItemId = 'plan-item-1'
      ..qty.text = '10'
      ..defectQty.text = '1.5';
    final copy = row.clone();
    addTearDown(copy.dispose);
    expect(copy.defectQty.text, '1.5');
  });

  testWidgets('不良数随表单草稿保存与恢复，清除来源时一并清空', (tester) async {
    await _pumpNewReport(tester, _api());
    final row = _productRows(tester).single;
    await tester.enterText(_defectField(row), '3.25');
    await tester.pump();
    final state =
        tester.state(find.byType(ProductionDailyReportEditPage))
            as FormDraftMixin<ProductionDailyReportEditPage>;
    final draft = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(state.captureFormDraft())) as Map,
    );
    expect(((draft['rows'] as List).single as Map)['defectQty'], '3.25');
    row.defectQty.clear();
    await state.restoreFormDraft(draft);
    await tester.pumpAndSettle();
    final restored = _productRows(tester).single;
    expect(restored.defectQty.text, '3.25');
    expect(restored.qty.text, '10');
    expect(_defectField(restored), findsOneWidget);
    // 「清除来源」在右侧来源列，先横向滚到可见再点。
    await tester.ensureVisible(find.byTooltip('清除来源'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清除来源'));
    await tester.pumpAndSettle();
    expect(restored.defectQty.text, '');
    expect(restored.executionSegmentId, isNull);
    expect(_defectField(restored), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ADR-129 §2.7 实盘收尾：最后一次报工逐料清点实际剩余。退回仓库时本次用料 =
  // 账面可用 - 实际剩余并带清点数；留在车间照旧不带；关掉弹窗回到报工表不保存。
  for (final choice in ['return', 'used-up', 'stay', 'dismiss']) {
    testWidgets('last report counted close-out: $choice', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      Map<String, dynamic>? saved;
      final api = _api(
        sourceOverrides: {
          'planId': 'plan-1',
          'plannedQty': 10,
          'producedQty': 0,
        },
        onCreate: (body) => saved = body,
        responseOverride: (request) {
          if (request.path.endsWith('/material-usage-sources')) {
            return [
              {
                'executionSegmentId': 'segment-1',
                'executionSegmentCode': 'SEG-001',
                'canOpen': true,
                'canSettle': true,
                'shared': false,
              },
            ];
          }
          if (request.path.endsWith('/clearance')) {
            return [
              {
                'planId': 'plan-1',
                'demandId': 'demand-1',
                'goodsId': 'raw',
                'goodsName': '测试原料',
                'unitName': '千克',
                'executionSegmentId': 'segment-1',
                'issuedQty': 10,
                'unclearedQty': 10,
                'availableToSettleQty': 10,
                'requiredQty': 10,
                'requiredForProductQty': 10,
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
              Perm.productionDailyReportView,
            }),
            formDraftStorageProvider.overrideWithValue(
              MemoryFormDraftStorage(),
            ),
            sessionProvider.overrideWith(_ExactSegmentSession.new),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'report-user'),
            ),
            sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
            apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionDailyReportCreate,
              Perm.productionDailyReportView,
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
      expect(
        grid.controller.rows.firstWhere((row) => !row.isMaterialRow).qty.text,
        '10',
      );
      final material = grid.controller.rows.firstWhere(
        (row) => row.materialEditable,
      );
      // 按单耗预填的用料正好用完账面：纸面剩余 0 也要清点。
      expect(material.materialUsed.text, '10');
      if (choice != 'used-up') material.materialUsed.text = '6';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(find.text('清点剩余物料'), findsOneWidget);
      expect(find.text('账面可用 10 千克'), findsOneWidget);
      final counted = find.byKey(
        const ValueKey('report-surplus-counted-demand-1'),
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: counted, matching: find.byType(TextField)),
            )
            .controller!
            .text,
        choice == 'used-up' ? '0' : '4',
      );
      if (choice == 'dismiss') {
        await tester.tapAt(const Offset(5, 5));
      } else {
        if (choice != 'used-up') await tester.enterText(counted, '3');
        await tester.pump();
        await tester.tap(
          choice == 'stay'
              ? find.text('留在车间')
              : find.byKey(const Key('report-surplus-return-confirm')),
        );
      }
      await tester.pumpAndSettle();
      if (choice == 'dismiss') {
        expect(saved, isNull);
        expect(find.text('清点剩余物料'), findsNothing);
        expect(material.materialUsed.text, '6');
      } else {
        expect(saved!['materialLines'], [
          switch (choice) {
            'return' => {
              'demandId': 'demand-1',
              'qtyBase': 7.0,
              'countedLeftoverQty': 3.0,
            },
            'used-up' => {
              'demandId': 'demand-1',
              'qtyBase': 10.0,
              'countedLeftoverQty': 0.0,
            },
            _ => {'demandId': 'demand-1', 'qtyBase': 6.0},
          },
        ]);
        expect(
          saved!['surplusReturnRequested'],
          choice == 'stay' ? isNull : isTrue,
        );
        // 页面只改提交的数；用料格仍是用户填的，服务端审核时按实际剩余覆盖。
        expect(material.materialUsed.text, choice == 'used-up' ? '10' : '6');
      }
      expect(tester.takeException(), isNull);
    });
  }
}

class _ReportSaveAttachments extends AttachmentService {
  _ReportSaveAttachments(super.api, {required this.failFirst});
  final bool failFirst;
  var attempts = 0;

  @override
  Future<Attachment> uploadCheckpointed({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    required bool Function() canContinue,
    required Future<void> Function(PresignResult) onPresigned,
    String? category,
  }) async {
    if (!canContinue()) throw StateError('scope changed');
    if (failFirst && attempts == 0) {
      attempts++;
      throw StateError(
        'fixture presign failed before a grant or bytes existed',
      );
    }
    await onPresigned(
      const PresignResult(
        storageKey: 'report-file',
        url: '/attachments/raw/report-file',
        method: 'PUT',
        contentType: 'text/plain',
        headers: {},
        formFields: {},
        confirmToken: 'fixture',
      ),
    );
    if (!canContinue()) throw StateError('scope changed');
    return upload(
      ownerType: ownerType,
      ownerId: ownerId,
      fileName: fileName,
      contentType: contentType,
      bytes: bytes,
      category: category,
    );
  }

  @override
  Future<Attachment> uploadGuarded({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    required bool Function() canContinue,
    String? category,
  }) {
    if (!canContinue()) throw StateError('scope changed before fixture upload');
    return upload(
      ownerType: ownerType,
      ownerId: ownerId,
      fileName: fileName,
      contentType: contentType,
      bytes: bytes,
      category: category,
    );
  }

  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    attempts++;
    if (failFirst && attempts == 1) {
      throw StateError('temporary upload failure');
    }
    return Attachment(
      id: 'attachment',
      uploadedBy: 'native-detail-reader',
      sha256: crypto.sha256.convert(bytes).toString(),
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: 'report-file',
      originalName: fileName,
      sizeBytes: bytes.length,
    );
  }
}

Future<void> _pumpNewReport(WidgetTester tester, ApiClient api) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
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
        employeeRepositoryProvider.overrideWithValue(_FakeEmployeeRepository()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionDailyReportCreate,
          Perm.productionDailyReportView,
        }),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_ExactSegmentSession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'report-user'),
        ),
        sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
        apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionDailyReportCreate,
          Perm.productionDailyReportView,
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
}

List<DailyGridRow> _productRows(WidgetTester tester) => tester
    .widget<UtenEditableGrid<DailyGridRow>>(
      find.byType(UtenEditableGrid<DailyGridRow>),
    )
    .controller
    .rows
    .where((row) => !row.isMaterialRow)
    .toList();

Finder _defectField(DailyGridRow row) => find.byWidgetPredicate(
  (widget) =>
      widget is TextField && identical(widget.controller, row.defectQty),
);

/// 去向分配页面测试的共用装配：新建日报带一个来源(完工申报量 10)，
/// 可送的上层工单 A 还差 6、B 还差 3，C 在别的车间不能收。
Future<UtenEditableGridController<DailyGridRow>> _pumpAllocationPage(
  WidgetTester tester, {
  void Function(Map<String, dynamic>)? onCreate,
  ProductionMaterialRepository Function(ApiClient api)? materialRepository,
}) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final api = _api(
    sourceOverrides: const {'planId': 'plan-1'},
    onCreate: onCreate,
    responseOverride: (request) =>
        request.path.endsWith('/direct-transfers/candidates')
        ? const {
            'candidates': [
              {
                'demandId': 'A',
                'executionSegmentId': 'segment-a',
                'executionSegmentCode': 'ZX-A',
                'receivingGoodsName': '成品甲',
                'remainingQty': 6,
              },
              {
                'demandId': 'B',
                'executionSegmentId': 'segment-b',
                'executionSegmentCode': 'ZX-B',
                'receivingGoodsName': '成品乙',
                'remainingQty': 3,
              },
            ],
            'blockedTargets': [
              {
                'demandId': 'C',
                'executionSegmentCode': 'ZX-C',
                'reasonCode': 'DIFFERENT_WORKSHOP',
                'reason': '上层工单 ZX-C 在二车间，跨车间必须送入仓库',
              },
            ],
            'receiverLimit': 30,
          }
        : null,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        if (materialRepository != null)
          productionMaterialRepositoryProvider.overrideWithValue(
            materialRepository(api),
          ),
        departmentRepositoryProvider.overrideWithValue(
          _FakeDepartmentRepository(),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        productionDailyReportRepositoryProvider.overrideWithValue(
          ProductionDailyReportRepository(api),
        ),
        employeeRepositoryProvider.overrideWithValue(_FakeEmployeeRepository()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionDailyReportCreate,
          Perm.productionDailyReportView,
        }),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_ExactSegmentSession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'report-user'),
        ),
        sessionSnapshotProvider.overrideWith(_ExactSegmentSnapshot.new),
        apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
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
  return tester
      .widget<UtenEditableGrid<DailyGridRow>>(
        find.byType(UtenEditableGrid<DailyGridRow>),
      )
      .controller;
}

/// 转给工单候选接口：[failing] 为真时读取失败(网络或服务端故障)，否则照常读。
class _FlakyCandidatesRepository extends ProductionMaterialRepository {
  _FlakyCandidatesRepository(super.api);

  bool failing = true;
  int calls = 0;

  @override
  Future<DirectTransferCandidatesResult> directTransferCandidates({
    required String executionSegmentId,
    required String goodsId,
    String? colorId,
  }) async {
    calls++;
    if (failing) throw StateError('候选接口暂时不可用');
    return super.directTransferCandidates(
      executionSegmentId: executionSegmentId,
      goodsId: goodsId,
      colorId: colorId,
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
        if (override is DioException) {
          handler.reject(override);
          return;
        }
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
