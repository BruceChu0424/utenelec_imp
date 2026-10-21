import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_return.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_return_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_iqc_stock_in_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_quality_result_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'original unknown quality confirmation survives unavailable scope reload',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1500);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final detail = _detailJson();
      final stock = _StockInGateway(unknownOnce: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(Dio())),
            warehouseQualityResultRepositoryProvider.overrideWithValue(
              _QualityGateway(detail),
            ),
            warehouseIqcStockInRepositoryProvider.overrideWithValue(stock),
            warehouseIqcReturnRepositoryProvider.overrideWithValue(
              _FailingReturnGateway(),
            ),
            sharedPreferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseIqcStockInView,
              Perm.warehouseIqcStockInConfirm,
            }),
          ],
          child: const MaterialApp(
            home: WarehouseQualityResultDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
              inspectionItemIds: ['inspection-1'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-inbound-allocation-confirm')),
      );
      await tester.pumpAndSettle();
      final editor =
          tester.state(find.byType(WarehouseQualityResultDetailPage))
              as FormDraftMixin<WarehouseQualityResultDetailPage>;
      final original = editor.captureFormDraft()['pendingCommand'];
      expect(original, isNotNull);
      expect(stock.confirmCalls, 1);
      detail['lines'] = (detail['lines'] as List)
          .cast<Map<String, dynamic>>()
          .where((line) => line['inspectionItemId'] != 'inspection-1')
          .toList();
      await tester.tap(
        find.byKey(const Key('warehouse-quality-detail-refresh')),
      );
      await tester.pumpAndSettle();
      expect(editor.captureFormDraft()['pendingCommand'], original);
      expect(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
        findsNothing,
      );
      final recovery = editor.formDraftSubmissionRecoveryAction as UtenButton;
      expect(recovery.onPressed, isNotNull);
      recovery.onPressed!();
      await tester.pumpAndSettle();
      expect(stock.confirmCalls, 2);
      expect(stock.lastCommand!.toJson(), original);
      expect(editor.captureFormDraft()['pendingCommand'], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quality confirmation cannot submit after its source scope reloads',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1500);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final detail = _detailJson();
      final stock = _StockInGateway();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(Dio())),
            warehouseQualityResultRepositoryProvider.overrideWithValue(
              _QualityGateway(detail),
            ),
            warehouseIqcStockInRepositoryProvider.overrideWithValue(stock),
            warehouseIqcReturnRepositoryProvider.overrideWithValue(
              _FailingReturnGateway(),
            ),
            sharedPreferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseIqcStockInView,
              Perm.warehouseIqcStockInConfirm,
            }),
          ],
          child: const MaterialApp(
            home: WarehouseQualityResultDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
              inspectionItemIds: ['inspection-1'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final refresh = tester
          .widget<UtenAppBarActionButton>(
            find.byKey(const Key('warehouse-quality-detail-refresh')),
          )
          .onPressed!;
      await tester.tap(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('warehouse-inbound-allocation-confirm')),
        findsOneWidget,
      );
      detail['lines'] = (detail['lines'] as List)
          .cast<Map<String, dynamic>>()
          .where((line) => line['inspectionItemId'] != 'inspection-1')
          .toList();
      refresh();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-inbound-allocation-confirm')),
      );
      await tester.pumpAndSettle();
      expect(stock.confirmCalls, 0);
      expect(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
        findsNothing,
      );
      final editor =
          tester.state(find.byType(WarehouseQualityResultDetailPage))
              as FormDraftMixin<WarehouseQualityResultDetailPage>;
      expect(editor.captureFormDraft()['pendingCommand'], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    'unselected',
    'selected',
    'stale',
    'network',
    'version',
  ]) {
    final selectedRejection = scenario != 'unselected';
    testWidgets(
      'scoped mixed quality detail keeps return selection $scenario',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1800, 1500);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final returns = _RecordingReturnGateway();
        final detail = {
          ..._detailJson(),
          'rejections': [
            {
              'id': 'rejection-c',
              'inspectionItemId': 'inspection-2',
              'goodsId': 'goods-2',
              'goodsName': '未合格产品C',
              'failedQty': 10,
              'physicalStatus': 'PENDING_RETURN',
              'rowVersion': 7,
              'canRecordReturn': true,
            },
          ],
        };
        final quality = _QualityGateway(detail);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(ApiClient(Dio())),
              warehouseQualityResultRepositoryProvider.overrideWithValue(
                quality,
              ),
              warehouseIqcStockInRepositoryProvider.overrideWithValue(
                _StockInGateway(),
              ),
              warehouseIqcReturnRepositoryProvider.overrideWithValue(returns),
              sharedPreferencesProvider.overrideWithValue(
                await SharedPreferences.getInstance(),
              ),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.warehouseIqcStockInView,
                Perm.warehouseIqcStockInConfirm,
                Perm.warehouseIqcReturnView,
                Perm.procurementIqcRejectionRecordReturn,
              }),
            ],
            child: MaterialApp(
              home: WarehouseQualityResultDetailPage(
                receiptType: 'PURCHASE',
                receiptId: 'receipt-1',
                inspectionItemIds: [
                  selectedRejection ? 'inspection-2' : 'inspection-0',
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(
          const ValueKey('quality-rejection-rejection-c'),
        );
        if (!selectedRejection) {
          expect(card, findsNothing);
          expect(find.text('登记退回'), findsNothing);
        } else {
          expect(card, findsOneWidget);
          if (scenario == 'stale' || scenario == 'network') {
            final stale = tester
                .widget<UtenButton>(find.widgetWithText(UtenButton, '登记退回'))
                .onPressed!;
            final originalLines = detail['lines'];
            if (scenario == 'stale') {
              detail['lines'] = (detail['lines'] as List)
                  .cast<Map<String, dynamic>>()
                  .where((line) => line['inspectionItemId'] != 'inspection-2')
                  .toList();
            } else {
              quality.nextError = ApiException('NETWORK_ERROR', '离线读取失败');
            }
            await tester.tap(
              find.byKey(const Key('warehouse-quality-detail-refresh')),
            );
            await tester.pumpAndSettle();
            expect(
              find.textContaining(
                scenario == 'stale' ? '所选品质放行明细已变化' : '离线读取失败',
              ),
              findsOneWidget,
            );
            expect(find.text('登记退回'), findsNothing);
            stale();
            await tester.pumpAndSettle();
            expect(find.byType(TextFormField), findsNothing);
            expect(returns.ids, isEmpty);
            detail['lines'] = originalLines;
            await tester.tap(
              find.byKey(const Key('warehouse-quality-detail-refresh')),
            );
            await tester.pumpAndSettle();
            expect(find.text('登记退回'), findsOneWidget);
          }
          final refresh = tester
              .widget<UtenAppBarActionButton>(
                find.byKey(const Key('warehouse-quality-detail-refresh')),
              )
              .onPressed!;
          await tester.ensureVisible(find.text('登记退回'));
          await tester.tap(find.text('登记退回'));
          await tester.pumpAndSettle();
          if (scenario == 'version') {
            (detail['rejections'] as List)
                    .cast<Map<String, dynamic>>()
                    .single['rowVersion'] =
                8;
            refresh();
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byType(TextFormField).at(0),
              'OLD-RETURN-C',
            );
            await tester.enterText(
              find.byType(TextFormField).at(1),
              '旧版本确认不能写入',
            );
            await tester.tap(find.text('确认登记'));
            await tester.pumpAndSettle();
            expect(returns.ids, isEmpty);
            await tester.ensureVisible(find.text('登记退回'));
            await tester.tap(find.text('登记退回'));
            await tester.pumpAndSettle();
          }
          final fields = find.byType(TextFormField);
          await tester.enterText(fields.at(0), 'RETURN-C-001');
          await tester.enterText(fields.at(1), '核对物料C实物退回');
          await tester.tap(find.text('确认登记'));
          await tester.pumpAndSettle();
          expect(returns.ids, ['rejection-c']);
          expect(
            returns.lastCommand!.expectedVersion,
            scenario == 'version' ? 8 : 7,
          );
        }
        expect(returns.ids, selectedRejection ? ['rejection-c'] : isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'physical inspection selection displays and posts only its release slices',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1500);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final preferences = await SharedPreferences.getInstance();
      final stock = _StockInGateway();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            warehouseQualityResultRepositoryProvider.overrideWithValue(
              _QualityGateway(_detailJson()),
            ),
            warehouseIqcStockInRepositoryProvider.overrideWithValue(stock),
            warehouseIqcReturnRepositoryProvider.overrideWithValue(
              _FailingReturnGateway(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseIqcStockInView,
              Perm.warehouseIqcStockInConfirm,
            }),
          ],
          child: const MaterialApp(
            home: WarehouseQualityResultDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
              inspectionItemIds: ['inspection-1'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quality-slice-qty-pass-1')), findsNothing);
      expect(find.byKey(const Key('quality-slice-qty-pass-2')), findsOneWidget);
      expect(find.byKey(const Key('quality-slice-qty-pass-3')), findsOneWidget);
      expect(find.text('确认入库(2)'), findsOneWidget);
      final editor =
          tester.state(find.byType(WarehouseQualityResultDetailPage))
              as FormDraftMixin<WarehouseQualityResultDetailPage>;
      expect(
        Uri.parse(
          editor.formDraftSpec.route,
        ).queryParameters['inspectionItemIds'],
        'inspection-1',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('warehouse-inbound-allocation-confirm')),
      );
      await tester.pumpAndSettle();
      expect(stock.lastCommand!.items.map((item) => item.passEventId), [
        'pass-2',
        'pass-3',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (
      name: 'sparse-superadmin-no-stock-view',
      permissions: <String>{
        Perm.warehouseIqcReturnView,
        Perm.warehouseIqcStockInConfirm,
      },
      superAdmin: true,
      readOnly: false,
      confirm: false,
      record: false,
    ),
    (
      name: 'stock-view-and-record-no-return-view',
      permissions: <String>{
        Perm.warehouseIqcStockInView,
        Perm.procurementIqcRejectionRecordReturn,
      },
      superAdmin: false,
      readOnly: false,
      confirm: false,
      record: false,
    ),
    (
      name: 'readonly-full-native-grants',
      permissions: <String>{
        Perm.warehouseIqcStockInView,
        Perm.warehouseIqcStockInConfirm,
        Perm.warehouseIqcReturnView,
        Perm.procurementIqcRejectionRecordReturn,
      },
      superAdmin: false,
      readOnly: true,
      confirm: false,
      record: false,
    ),
    (
      name: 'full-native-grants',
      permissions: <String>{
        Perm.warehouseIqcStockInView,
        Perm.warehouseIqcStockInConfirm,
        Perm.warehouseIqcReturnView,
        Perm.procurementIqcRejectionRecordReturn,
      },
      superAdmin: false,
      readOnly: false,
      confirm: true,
      record: true,
    ),
  ]) {
    testWidgets(
      'ordinary detail obeys native grants and readonly ${scenario.name}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1800, 1500);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preferences = await SharedPreferences.getInstance();
        final detail = {
          ..._detailJson(),
          'rejections': [
            {
              'id': 'rejection-a',
              'inspectionItemId': 'inspection-failed',
              'goodsId': 'goods-2',
              'failedQty': 2,
              'physicalStatus': 'PENDING_RETURN',
              'rowVersion': 7,
              'canRecordReturn': true,
            },
          ],
        };
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              warehouseQualityResultRepositoryProvider.overrideWithValue(
                _QualityGateway(detail),
              ),
              warehouseIqcStockInRepositoryProvider.overrideWithValue(
                _StockInGateway(),
              ),
              warehouseIqcReturnRepositoryProvider.overrideWithValue(
                _FailingReturnGateway(),
              ),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue(
                scenario.permissions,
              ),
              isSuperAdminProvider.overrideWithValue(scenario.superAdmin),
              if (scenario.readOnly)
                authenticatedScopeProvider.overrideWithValue(
                  const AuthenticatedScope(userId: 'keeper', readOnly: true),
                ),
            ],
            child: const MaterialApp(
              home: WarehouseQualityResultDetailPage(
                receiptType: 'PURCHASE',
                receiptId: 'receipt-1',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('warehouse-quality-detail-confirm')),
          scenario.confirm ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('登记退回'),
          scenario.record ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('inspection line verdict derives from quantities and open status', () {
    WarehouseQualityInspectionLine line(Map<String, dynamic> json) =>
        WarehouseQualityInspectionLine.fromJson(json);

    // 合格：有合格量、无不合格、检验已结案 → 绿色对勾口径。
    expect(
      line(const {
        'inspectionItemId': 'i-1',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 10,
        'failedBaseQty': 0,
        'lineStatus': 'RESOLVED',
      }).verdict,
      WarehouseQualityLineVerdict.passed,
    );
    // 不合格：只有不合格量 → 红色禁止口径。
    expect(
      line(const {
        'inspectionItemId': 'i-2',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 0,
        'failedBaseQty': 10,
        'lineStatus': 'RESOLVED',
      }).verdict,
      WarehouseQualityLineVerdict.rejected,
    );
    // 部分合格：合格 + 不合格（或仍有待检余量）→ 黄色警告口径。
    expect(
      line(const {
        'inspectionItemId': 'i-3',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 6,
        'failedBaseQty': 4,
        'lineStatus': 'RESOLVED',
      }).verdict,
      WarehouseQualityLineVerdict.partial,
    );
    expect(
      line(const {
        'inspectionItemId': 'i-4',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 6,
        'failedBaseQty': 0,
        'lineStatus': 'PARTIAL',
      }).verdict,
      WarehouseQualityLineVerdict.partial,
    );
    // 待检：尚无结论 → 蓝色沙漏口径。
    expect(
      line(const {
        'inspectionItemId': 'i-5',
        'goodsId': 'g-1',
        'receivedBaseQty': 10,
        'passedBaseQty': 0,
        'failedBaseQty': 0,
        'lineStatus': 'PENDING',
      }).verdict,
      WarehouseQualityLineVerdict.waiting,
    );
  });

  test(
    'allocation model parses four kinds, truncates in order and tolerates old responses',
    () {
      final allocations = [
        for (final row in _fourExpectedAllocations)
          WarehouseInboundAllocation.fromJson(row),
      ];
      expect(allocations.map((item) => item.kind), [
        WarehouseInboundAllocationKind.formalDemand,
        WarehouseInboundAllocationKind.exactAnalysis,
        WarehouseInboundAllocationKind.sharedClaim,
        WarehouseInboundAllocationKind.publicStock,
      ]);
      final preview = warehouseInboundAllocationPreview(allocations, 6);
      expect(preview.map((item) => item.qty), [2, 4]);
      expect(preview.map((item) => item.kind), [
        WarehouseInboundAllocationKind.formalDemand,
        WarehouseInboundAllocationKind.exactAnalysis,
      ]);
      final guardedGap = warehouseInboundAllocationPreview(allocations, 12);
      expect(guardedGap.last.kind, WarehouseInboundAllocationKind.unknown);
      expect(guardedGap.last.qty, 2);
      expect(guardedGap.last.formationStatus, contains('差额去向待服务端复核'));
      expect(
        WarehouseIqcStockInConfirmResult.fromJson(const {
          'batchId': 'legacy-batch',
          'confirmedCount': 1,
        }).allocations,
        isEmpty,
      );
      expect(
        WarehouseQualityReleasedSlice.fromJson(
          _sliceJson('legacy', 'inspection', 'goods', 'G', '旧响应', 1),
        ).expectedAllocations,
        isEmpty,
      );
    },
  );

  testWidgets(
    'charged and gift releases are both counted and submitted by distinct event IDs',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1800, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final detail = {
        ..._detailJson(),
        'lines': [
          for (final pair in [
            ('charged-inspection', 'CHARGED', 10),
            ('gift-inspection', 'GIFT', 1),
          ])
            {
              'inspectionItemId': pair.$1,
              'goodsId': 'same-goods',
              'goodsCode': 'SAME',
              'goodsName': '同一业务行材料',
              'unitId': 'unit-1',
              'unitName': '件',
              'quantityTranche': pair.$2,
              'lineStatus': 'RESOLVED',
              'receivedBaseQty': pair.$3,
              'passedBaseQty': pair.$3,
              'failedBaseQty': 0,
              'warehouseStockedBaseQty': 0,
              'pendingStockBaseQty': pair.$3,
            },
        ],
        'items': [
          {
            ..._sliceJson(
              'charged-pass',
              'charged-inspection',
              'same-goods',
              'SAME',
              '同一业务行材料',
              10,
            ),
            'quantityTranche': 'CHARGED',
          },
          {
            ..._sliceJson(
              'gift-pass',
              'gift-inspection',
              'same-goods',
              'SAME',
              '同一业务行材料',
              1,
            ),
            'quantityTranche': 'GIFT',
          },
        ],
      };
      final gateway = _StockInGateway();
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            warehouseQualityResultRepositoryProvider.overrideWithValue(
              _QualityGateway(detail),
            ),
            warehouseIqcStockInRepositoryProvider.overrideWithValue(gateway),
            warehouseIqcReturnRepositoryProvider.overrideWithValue(
              _FailingReturnGateway(),
            ),
            sharedPreferencesProvider.overrideWithValue(prefs),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseIqcStockInView,
              Perm.warehouseIqcStockInConfirm,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: WarehouseQualityResultDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认入库(2)'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('赠品'), findsWidgets);
      expect(find.textContaining('收费'), findsWidgets);
      await tester.tap(
        find.byKey(const Key('warehouse-inbound-allocation-confirm')),
      );
      await tester.pumpAndSettle();
      expect(gateway.confirmCalls, 1);
      final items = gateway.lastCommand!.items;
      expect(items.map((row) => row.passEventId).toSet(), {
        'charged-pass',
        'gift-pass',
      });
      expect(items.map((row) => row.baseQty).toList(), [10.0, 1.0]);
      expect(items.map((row) => row.expectedRemainingBaseQty).toList(), [
        10.0,
        1.0,
      ]);
    },
  );

  testWidgets(
    'merged table joins verdicts and releasable slices with solo-confirm path',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final qualityGateway = _QualityGateway(_detailJson());
      final stockInGateway = _StockInGateway(
        allocations: _singleActualAllocations,
      );
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            warehouseQualityResultRepositoryProvider.overrideWithValue(
              qualityGateway,
            ),
            warehouseIqcStockInRepositoryProvider.overrideWithValue(
              stockInGateway,
            ),
            warehouseIqcReturnRepositoryProvider.overrideWithValue(
              _FailingReturnGateway(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.warehouseIqcStockInView,
              Perm.warehouseIqcStockInConfirm,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: WarehouseQualityResultDetailPage(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 单据信息 + 合并明细表（一张表：判定 + 放行切片同场）。
      expect(find.text('PR-001'), findsOneWidget);
      expect(find.text('检查结果与待入库明细'), findsOneWidget);
      // 精确表头（无必填星标）。检验状态列已并入判定结果（2026-09-03 表头清理）。
      for (final header in const [
        '判定结果',
        '货品名称',
        '收货总量',
        '合格总量',
        '不合格总量',
        '预计去向',
        '放行信息',
      ]) {
        expect(find.text(header), findsOneWidget, reason: '缺列 $header');
      }
      // 必填列表头带红 *（如「货品库位 *」），用包含匹配。
      expect(find.textContaining('实际库位'), findsWidgets);
      expect(find.textContaining('本次实收'), findsWidgets);
      expect(find.text('合格待入量'), findsOneWidget);
      expect(find.textContaining('目标叶仓'), findsWidgets);
      expect(find.text('供应商 / 委外商'), findsOneWidget);
      // 2026-10-10「数量 + 单位」内联口径：单位列删除，数量格直接带单位（件）。
      expect(find.text('单位'), findsNothing);
      // 逐行判定（图标旁判定文案始终在场，不只靠颜色）。
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      // 黄色警告图标出现三次：单人兼任提示横幅 + 部分合格判定随 2 个切片行出现。
      expect(find.byIcon(Icons.warning_amber_rounded), findsNWidgets(3));
      expect(find.byIcon(Icons.block), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_top_outlined), findsOneWidget);
      // 合并表按切片行展开：部分合格明细行的判定文案随 2 个切片行出现 2 次。
      expect(find.text('部分合格'), findsNWidgets(2));
      expect(find.text('不合格'), findsOneWidget);
      // 同一明细行拆 2 个放行切片 → 货品列标注「切片 i/2」防误读。
      expect(find.text('切片 1/2'), findsOneWidget);
      expect(find.text('切片 2/2'), findsOneWidget);
      // 可办理行默认全额 + 建议库位预填（底部确认按钮计数 = 切片数）。
      expect(find.text('确认入库(3)'), findsOneWidget);

      // 单人兼任：放行人是本人 → 复核提示在场但不阻断确认按钮。
      expect(
        find.byKey(const Key('warehouse-quality-detail-own-release')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
        findsOneWidget,
      );

      // 确认入库：改一条库位 → 复核弹窗 → 提交单张确认命令（含预填与手填库位）。
      await tester.enterText(
        find.byKey(const Key('quality-slice-qty-pass-1')),
        '5',
      );
      await tester.enterText(
        find.byKey(const Key('quality-slice-place-pass-1')),
        'B-02',
      );
      await tester.tap(
        find.byKey(const Key('warehouse-quality-detail-confirm')),
      );
      await tester.pumpAndSettle();
      // 2026-09-12 确认弹窗改紧凑摘要（用户口径「小点」）：货品行一行
      // 「品名 + 本次数量 + 去向一句话」；完整去向明细在表格 ⓘ 的
      // 「查看去向明细」里，不再塞进确认弹窗。
      final confirmDialog = find.byKey(
        const Key('warehouse-inbound-allocation-confirm-dialog'),
      );
      expect(
        find.descendant(of: confirmDialog, matching: find.text('本次 5 件')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: confirmDialog,
          matching: find.text('计划部预定 4 · 公共在途已采用 1'),
        ),
        findsOneWidget,
      );
      expect(find.text('数量 4 件'), findsNothing);
      await tester.tap(
        find.byKey(const Key('warehouse-inbound-allocation-confirm')),
      );
      await tester.pumpAndSettle();

      // 2026-09-16 全站口径：提交期间全屏加载遮罩，成功只走顶部通知条，
      // 不再弹「入库完成 · 实际去向」中间结果框（少一步关闭操作）；实际
      // 去向随下方入库历史刷新落位。
      expect(
        find.byKey(const Key('warehouse-inbound-allocation-result-dialog')),
        findsNothing,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WarehouseQualityResultDetailPage)),
      );
      final notifications = container.read(appNotificationProvider);
      expect(notifications.single.message, '成功入库 3 条放行明细，实际去向见下方入库历史');
      expect(
        container.read(appNotificationProvider).single.kind,
        AppNotificationKind.success,
      );

      expect(stockInGateway.confirmCalls, 1);
      final command = stockInGateway.lastCommand!;
      expect(command.idempotencyKey, isNotEmpty);
      expect(command.items.length, 3);
      final byPassEvent = {
        for (final item in command.items) item.passEventId: item,
      };
      expect(byPassEvent['pass-1']!.place, 'B-02');
      expect(byPassEvent['pass-2']!.place, 'A-01');
      expect(byPassEvent['pass-1']!.baseQty, 5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial confirm conflict preserves merged-table inputs', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final qualityGateway = _QualityGateway(_detailJson());
    final stockInGateway = _StockInGateway(conflictOnce: true);
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseQualityResultRepositoryProvider.overrideWithValue(
            qualityGateway,
          ),
          warehouseIqcStockInRepositoryProvider.overrideWithValue(
            stockInGateway,
          ),
          warehouseIqcReturnRepositoryProvider.overrideWithValue(
            _FailingReturnGateway(),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInView,
            Perm.warehouseIqcStockInConfirm,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: WarehouseQualityResultDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const quantityKey = Key('quality-slice-qty-pass-1');
    const placeKey = Key('quality-slice-place-pass-1');
    await tester.enterText(find.byKey(quantityKey), '3.5');
    await tester.enterText(find.byKey(placeKey), 'B-02');
    await tester.tap(find.byKey(const Key('warehouse-quality-detail-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('warehouse-inbound-allocation-confirm')),
    );
    await tester.pumpAndSettle();

    // 冲突 → 整批未入库、刷新事实并保留当前输入。
    expect(stockInGateway.confirmCalls, 1);
    expect(qualityGateway.detailCalls, greaterThanOrEqualTo(2));
    final command = stockInGateway.lastCommand!;
    final edited = {
      for (final item in command.items) item.passEventId: item,
    }['pass-1']!;
    expect(edited.baseQty, 3.5);
    expect(edited.place, 'B-02');
    expect(
      tester.widget<TextFormField>(find.byKey(quantityKey)).controller?.text,
      '3.5',
    );
    expect(
      tester.widget<TextFormField>(find.byKey(placeKey)).controller?.text,
      'B-02',
    );
    expect(find.textContaining('已保留当前输入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only permission hides confirm bar and inputs', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseQualityResultRepositoryProvider.overrideWithValue(
            _QualityGateway(_detailJson()),
          ),
          warehouseIqcStockInRepositoryProvider.overrideWithValue(
            _StockInGateway(),
          ),
          warehouseIqcReturnRepositoryProvider.overrideWithValue(
            _FailingReturnGateway(),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.procurementIqcRejectionRecordReturn,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: WarehouseQualityResultDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 无确认双权限：不出确认底栏与任何输入/勾选单元，明细表仍只读可见。
    expect(
      find.byKey(const Key('warehouse-quality-detail-confirm')),
      findsNothing,
    );
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    // 合并表按切片行展开：部分合格 ×2 切片 → 判定文案出现 2 次（只读无输入框）。
    expect(find.text('部分合格'), findsNWidgets(2));
    expect(find.text('只读'), findsNothing);
    expect(find.textContaining('当前为只读查看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed receipt keeps merged table read-only with history', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warehouseQualityResultRepositoryProvider.overrideWithValue(
            _QualityGateway(_completedDetailJson()),
          ),
          warehouseIqcStockInRepositoryProvider.overrideWithValue(
            _StockInGateway(),
          ),
          warehouseIqcReturnRepositoryProvider.overrideWithValue(
            _FailingReturnGateway(),
          ),
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.warehouseIqcStockInView,
            Perm.warehouseIqcStockInConfirm,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: WarehouseQualityResultDetailPage(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 已完结：无待入库切片 → 无勾选/输入/确认；入库历史只读在场。
    expect(
      find.byKey(const Key('warehouse-quality-detail-confirm')),
      findsNothing,
    );
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('实际库位 C-03'), findsOneWidget);
    expect(find.textContaining('仓库员'), findsOneWidget);
    expect(find.textContaining('正式工单 10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 四行判定（合格 / 部分合格×2切片 / 不合格 / 待检）+ 三个待入库放行切片。
Map<String, dynamic> _detailJson() => {
  'workStatus': 'ALL_PASSED',
  'receiptType': 'PURCHASE',
  'receiptId': 'receipt-1',
  'billNo': 'PR-001',
  'billDate': '2026-08-31',
  'supplierId': 'supplier-1',
  'supplierName': '示例供应商',
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'qualityStatus': 'RESOLVED',
  'goodsLineCount': 4,
  'passedLineCount': 1,
  'failedLineCount': 2,
  'openItemCount': 1,
  'pendingSliceCount': 3,
  'pendingReturnCount': 0,
  'completed': false,
  'containsOwnRelease': true,
  'allowedActions': <String>['CONFIRM'],
  'lines': [
    for (final (index, verdict) in [
      ('RESOLVED', 10, 10, 0),
      ('RESOLVED', 10, 6, 4),
      ('RESOLVED', 10, 0, 10),
      ('PENDING', 10, 0, 0),
    ].indexed)
      {
        'inspectionItemId': 'inspection-$index',
        'goodsId': 'goods-$index',
        'goodsCode': 'G-00$index',
        'goodsName': '测试产品$index',
        'colorName': null,
        'unitId': 'unit-1',
        'unitName': '件',
        'lineStatus': verdict.$1,
        'receivedBaseQty': verdict.$2,
        'passedBaseQty': verdict.$3,
        'failedBaseQty': verdict.$4,
        'warehouseStockedBaseQty': 0,
        'pendingStockBaseQty': switch (index) {
          0 => 10,
          1 => 6,
          _ => 0,
        },
      },
  ],
  'items': [
    {
      ..._sliceJson('pass-1', 'inspection-0', 'goods-0', 'G-000', '测试产品0', 10),
      'expectedAllocations': _singleExpectedAllocations,
    },
    _sliceJson('pass-2', 'inspection-1', 'goods-1', 'G-001', '测试产品1', 3),
    _sliceJson('pass-3', 'inspection-1', 'goods-1', 'G-001', '测试产品1', 3),
  ],
  'history': <Map<String, dynamic>>[],
  'rejections': <Map<String, dynamic>>[],
};

Map<String, dynamic> _sliceJson(
  String passEventId,
  String inspectionItemId,
  String goodsId,
  String goodsCode,
  String goodsName,
  num remaining,
) => {
  'passEventId': passEventId,
  'warehouseId': 'warehouse-1',
  'warehouseName': '原料仓',
  'inspectionItemId': inspectionItemId,
  'goodsId': goodsId,
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'colorName': null,
  'unitId': 'unit-1',
  'unitName': '件',
  'sourceOrderNo': 'PO-001',
  'receivedBaseQty': 10,
  'qualityPassedBaseQty': remaining,
  'warehouseStockedBaseQty': 0,
  'releasedBaseQty': remaining,
  'stockedForReleaseBaseQty': 0,
  'remainingBaseQty': remaining,
  'releasedWeight': null,
  'placeHint': 'A-01',
  'releaseNote': '抽检合格',
  'releasedBy': '当前账号',
  'releasedAt': '2026-08-31T09:00:00Z',
};

/// 已完结：切片全部入库，只余历史。
Map<String, dynamic> _completedDetailJson() => {
  ..._detailJson(),
  'workStatus': 'COMPLETED',
  'pendingSliceCount': 0,
  'completed': true,
  'allowedActions': <String>[],
  'containsOwnRelease': false,
  'items': <Map<String, dynamic>>[],
  'lines': [
    {
      'inspectionItemId': 'inspection-0',
      'goodsId': 'goods-0',
      'goodsCode': 'G-000',
      'goodsName': '测试产品0',
      'colorName': null,
      'unitId': 'unit-1',
      'unitName': '件',
      'lineStatus': 'RESOLVED',
      'receivedBaseQty': 10,
      'passedBaseQty': 10,
      'failedBaseQty': 0,
      'warehouseStockedBaseQty': 10,
      'pendingStockBaseQty': 0,
    },
  ],
  'history': [
    {
      'stockInItemId': 'stock-in-1',
      'batchId': 'batch-1',
      'passEventId': 'pass-1',
      'goodsId': 'goods-0',
      'goodsCode': 'G-000',
      'goodsName': '测试产品0',
      'colorName': null,
      'unitName': '件',
      'baseQty': 10,
      'weight': null,
      'place': 'C-03',
      'confirmedBy': '仓库员',
      'confirmedAt': '2026-08-31T10:30:00Z',
      'actualAllocations': [
        _allocationJson(
          kind: 'FORMAL_DEMAND',
          qty: 10,
          passEventId: 'pass-1',
          stockInBatchItemId: 'stock-in-1',
          planNo: 'SC-001',
          segmentCode: 'GD-001',
        ),
      ],
    },
  ],
  'rejections': <Map<String, dynamic>>[],
};

class _QualityGateway implements WarehouseQualityResultGateway {
  _QualityGateway(this.detailJson);

  final Map<String, dynamic> detailJson;
  int detailCalls = 0;
  Object? nextError;

  @override
  Future<WarehouseQualityResultDetail> detail(
    String receiptType,
    String receiptId,
  ) async {
    detailCalls++;
    final error = nextError;
    nextError = null;
    if (error != null) throw error;
    return WarehouseQualityResultDetail.fromJson(detailJson);
  }

  @override
  Future<Map<WarehouseQualityWorkStatus, int>> statusCounts({
    WarehouseTaskView view = WarehouseTaskView.active,
    WarehouseIqcStockInReceiptType? receiptType,
    String? keyword,
    String? scopeWarehouseId,
  }) async => throw StateError('unexpected status counts');

  @override
  Future<WarehouseQualityBatchConfirmResult> batchConfirm(
    WarehouseQualityBatchConfirmCommand command,
  ) async => throw StateError('unexpected batch confirm');

  @override
  Future<List<MasterFacetBucket>> billNoFacets({
    WarehouseTaskView view = WarehouseTaskView.active,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
    String? scopeWarehouseId,
  }) async => const []; // 2026-09-25 单号列统一：页面 facets 静默降级。
  @override
  Future<PagedResult<WarehouseQualityResultTask>> list({
    WarehouseTaskView view = WarehouseTaskView.active,
    int page = 1,
    int size = 40,
    WarehouseIqcStockInReceiptType? receiptType,
    WarehouseQualityWorkStatus? workStatus,
    String? keyword,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    String? billNo,
    String? scopeWarehouseId,
  }) async => throw StateError('unexpected list');
}

class _StockInGateway implements WarehouseIqcStockInGateway {
  _StockInGateway({
    this.conflictOnce = false,
    this.unknownOnce = false,
    this.allocations = const [],
  });

  final bool conflictOnce;
  final bool unknownOnce;
  final List<WarehouseInboundAllocation> allocations;
  int confirmCalls = 0;
  WarehouseIqcStockInConfirmCommand? lastCommand;

  @override
  Future<WarehouseIqcStockInConfirmResult> confirm(
    String receiptType,
    String receiptId,
    WarehouseIqcStockInConfirmCommand command,
  ) async {
    confirmCalls++;
    lastCommand = command;
    if (unknownOnce && confirmCalls == 1) {
      throw ApiException('NETWORK_ERROR', '未取得原入库回执');
    }
    if (conflictOnce && confirmCalls == 1) {
      throw ApiException('CONFLICT', '品质放行待入库余量已变化');
    }
    return WarehouseIqcStockInConfirmResult(
      batchId: 'batch-1',
      replayed: unknownOnce,
      confirmedCount: command.items.length,
      confirmedAt: '2026-09-01T10:00:00Z',
      allocations: allocations,
    );
  }

  @override
  Future<WarehouseIqcPreStockInResult> preStockIn(
    String receiptType,
    String receiptId,
    WarehouseIqcPreStockInCommand command,
  ) async => throw StateError('unexpected pre-stock-in');
}

final List<Map<String, dynamic>> _fourExpectedAllocations = [
  _allocationJson(kind: 'FORMAL_DEMAND', qty: 2),
  _allocationJson(kind: 'EXACT_ANALYSIS', qty: 4),
  _allocationJson(kind: 'SHARED_CLAIM', qty: 3),
  _allocationJson(kind: 'PUBLIC', qty: 1),
];

final List<Map<String, dynamic>> _singleExpectedAllocations = [
  _allocationJson(kind: 'EXACT_ANALYSIS', qty: 4),
  _allocationJson(kind: 'SHARED_CLAIM', qty: 3),
  _allocationJson(kind: 'PUBLIC', qty: 3),
];

final List<WarehouseInboundAllocation> _singleActualAllocations = [
  WarehouseInboundAllocation.fromJson(
    _allocationJson(
      kind: 'FORMAL_DEMAND',
      qty: 4,
      passEventId: 'pass-1',
      stockInBatchItemId: 'stock-in-result-1',
      planNo: 'SC-001',
      segmentCode: 'GD-001',
    ),
  ),
  WarehouseInboundAllocation.fromJson(
    _allocationJson(
      kind: 'PUBLIC',
      qty: 1,
      passEventId: 'pass-1',
      stockInBatchItemId: 'stock-in-result-1',
    ),
  ),
];

Map<String, dynamic> _allocationJson({
  required String kind,
  required num qty,
  String? passEventId,
  String? stockInBatchItemId,
  String? planNo,
  String? segmentCode,
}) => {
  'passEventId': passEventId ?? 'pass-model',
  'stockInBatchItemId': stockInBatchItemId,
  'kind': kind,
  'qty': qty,
  'actualWarehouseId': 'warehouse-1',
  'actualWarehouseName': '原料仓',
  'targetWarehouseId': kind == 'PUBLIC' ? null : 'warehouse-1',
  'targetWarehouseName': kind == 'PUBLIC' ? null : '原料仓',
  'intendedWarehouseNames': kind == 'PUBLIC' ? <String>[] : ['原料仓'],
  'warehouseMatches': true,
  'analysisId': kind == 'PUBLIC' ? null : 'analysis-1',
  'analysisMaterialId': kind == 'PUBLIC' ? null : 'material-1',
  'productCode': kind == 'PUBLIC' ? null : 'CP-001',
  'productName': kind == 'PUBLIC' ? null : '成品一',
  'sourceLabel': kind == 'PUBLIC' ? '公共库存' : '销售订单 XS-001',
  'planId': planNo == null ? null : 'plan-1',
  'planNo': planNo,
  'executionSegmentId': segmentCode == null ? null : 'segment-1',
  'executionSegmentCode': segmentCode,
  'workshopDepartmentId': segmentCode == null ? null : 'workshop-1',
  'workshopName': segmentCode == null ? null : '装配车间',
  'responsibleEmployeeId': segmentCode == null ? null : 'employee-1',
  'responsibleEmployeeName': segmentCode == null ? null : '张负责人',
  'formationStatus': kind == 'PUBLIC'
      ? '实际入库后未形成生产预留，已进入公共库存'
      : segmentCode == null
      ? '尚未形成生产计划或工单'
      : '已转入正式工单物料预留',
};

class _FailingReturnGateway implements WarehouseIqcReturnGateway {
  @override
  Future<WarehouseIqcReturnTask> recordReturn(
    String rejectionId,
    WarehouseIqcRecordReturnCommand command,
  ) async => throw StateError('unexpected record return');
}

class _RecordingReturnGateway implements WarehouseIqcReturnGateway {
  final ids = <String>[];
  WarehouseIqcRecordReturnCommand? lastCommand;
  @override
  Future<WarehouseIqcReturnTask> recordReturn(
    String id,
    WarehouseIqcRecordReturnCommand command,
  ) async {
    ids.add(id);
    lastCommand = command;
    return WarehouseIqcReturnTask(id: id, version: 8, allowedActions: const {});
  }
}
