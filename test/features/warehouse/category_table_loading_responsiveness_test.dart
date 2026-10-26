import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/pages/procurement_iqc_rejection_list_page.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_inspections_page.dart';
import 'package:uten_imp/features/quality/pages/quality_inspection_records_page.dart';
import 'package:uten_imp/features/quality/pages/quality_pending_disposal_page.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_quality_result.dart';
import 'package:uten_imp/features/warehouse/pages/finance_arrival_exception_pages.dart';
import 'package:uten_imp/features/warehouse/pages/procurement_return_task_pages.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_quality_results_page.dart';
import 'package:uten_imp/features/warehouse/pages/shelf_label_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_bin_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_machines_tab.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_prep_tab.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_arrival_exceptions_view.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_expectations_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

void main() {
  for (final preparation in [false, true]) {
    testWidgets(
      'denied workshop editor hides rows and retains inputs (prep=$preparation)',
      (tester) async {
        final api = _DeniedEditorApi();
        await _pump(
          tester,
          Scaffold(
            body: preparation
                ? const WmPrepTab(workshopId: 'w')
                : const WmMachinesTab(workshopId: 'w', workshopName: '车间'),
          ),
          api,
        );
        final key = Key(preparation ? 'wm-prep-grid' : 'wm-machines-grid');
        if (preparation) {
          final original = tester
              .widget<UtenEditableGrid<WmPrepRow>>(find.byKey(key))
              .controller;
          original.rows.single.grams.text = '30';
          await tester.tap(find.byKey(const Key('wm-prep-save')));
          await tester.pumpAndSettle();
          final visible = tester.widget<UtenEditableGrid<WmPrepRow>>(
            find.byKey(key),
          );
          expect(visible.controller.rows, isEmpty);
          expect(original.rows.single.grams.text, '30');
          expect(
            tester
                .widget<UtenButton>(find.byKey(const Key('wm-prep-save')))
                .onPressed,
            isNull,
          );
        } else {
          final original = tester
              .widget<UtenEditableGrid<WmMachineRow>>(find.byKey(key))
              .controller;
          original.rows.single.name.text = '保留的输入';
          await tester.tap(find.byKey(const Key('wm-machines-save')));
          await tester.pumpAndSettle();
          final visible = tester.widget<UtenEditableGrid<WmMachineRow>>(
            find.byKey(key),
          );
          expect(visible.controller.rows, isEmpty);
          expect(original.rows.single.name.text, '保留的输入');
          expect(
            tester
                .widget<UtenButton>(find.byKey(const Key('wm-machines-save')))
                .onPressed,
            isNull,
          );
        }
        expect(find.text('读取权限已变化'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final changeQuery in [false, true]) {
    testWidgets(
      'inbound query/denial retires old rows (new query=$changeQuery)',
      (tester) async {
        final api = _AcceptedThenPendingInbound();
        final refreshTick = ValueNotifier<int>(0);
        addTearDown(refreshTick.dispose);
        await _pump(
          tester,
          Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: refreshTick,
              builder: (_, tick, _) =>
                  WarehouseInboundExpectationsView(refreshTick: tick),
            ),
          ),
          api,
        );
        final finder = find.byKey(const Key('inbound-expectation-task-table'));
        MasterDataTableView<InboundExpectation> table() =>
            tester.widget(finder);
        expect(table().items.single.id, 'expectation-1');
        final element = tester.element(finder);
        if (changeQuery) {
          table().onFilterChanged('supplierName', 'supplier-2');
        } else {
          refreshTick.value++;
        }
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.element(finder), same(element));
        expect(
          table().items.isEmpty,
          changeQuery,
          reason: 'only a refresh of the same accepted query may retain rows',
        );
        expect(
          api.calls,
          2,
          reason: 'the real refresh must bypass the accepted page cache',
        );
        api.pending.completeError(
          ApiException('FORBIDDEN', '无权查看', httpStatus: 403),
        );
        await tester.pumpAndSettle();
        expect(table().items, isEmpty);
        expect(table().error, '无权查看');
        expect(tester.element(finder), same(element));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final entry in <(String, Widget, String)>[
    (
      'workshop material overview',
      const WorkshopMaterialBinPage(),
      'wm-overview-table',
    ),
    (
      'workshop machines',
      const Scaffold(
        body: WmMachinesTab(workshopId: 'w', workshopName: '车间'),
      ),
      'wm-machines-grid',
    ),
    (
      'workshop preparation',
      const Scaffold(body: WmPrepTab(workshopId: 'w')),
      'wm-prep-grid',
    ),
    (
      'FQC',
      const ProductionFqcInspectionsPage(),
      'production-fqc-inspection-table',
    ),
    (
      'records',
      const QualityInspectionRecordsPage(),
      'quality-inspection-record-table',
    ),
    (
      'pending disposal',
      const QualityPendingDisposalPage(),
      'iqc-receipt-table',
    ),
    (
      'arrival exceptions',
      const Scaffold(body: WarehouseArrivalExceptionsView()),
      'warehouse-arrival-exception-task-table',
    ),
    (
      'inbound expectations',
      const Scaffold(body: WarehouseInboundExpectationsView()),
      'inbound-expectation-task-table',
    ),
    (
      'IQC rejection',
      const ProcurementIqcRejectionListPage(),
      'iqc-rejection-task-table',
    ),
  ]) {
    testWidgets('${entry.$1} mounts table before the first response', (
      tester,
    ) async {
      await _pump(tester, entry.$2, _DelayedApi());
      expect(find.byKey(Key(entry.$3)), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'shelf rows start before warehouse dictionary enrichment finishes',
    (tester) async {
      final api = _DelayedApi();
      await _pump(tester, const ShelfLabelPage(), api);
      expect(api.held, contains('/stock/shelf-labels'));
      expect(
        find.byWidgetPredicate((widget) => widget is MasterDataTableView),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('IQC empty rows do not wait for independent category counts', (
    tester,
  ) async {
    final api = _DelayedApi(countsOnly: true);
    await _pump(tester, const ProcurementIqcRejectionListPage(), api);
    await selectFilterSegment(tester, '待退回');
    await tester.pumpAndSettle();
    final table = tester
        .widget<MasterDataTableView<ProcurementIqcRejectionCase>>(
          find.byKey(const Key('iqc-rejection-task-table')),
        );
    expect(table.isLoading, isFalse);
    expect(table.items, isEmpty);
    expect(api.held.where((path) => path.endsWith('/counts')), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending disposal rows do not wait for decision capability', (
    tester,
  ) async {
    final api = _DelayedApi(countsOnly: true, holdCapability: true);
    await _pump(tester, const QualityPendingDisposalPage(), api);
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byKey(const Key('iqc-receipt-table')),
    );
    expect(table.isLoading, isFalse);
    expect(table.items, isEmpty);
    expect(api.held.where((path) => path.endsWith('/capability')), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('warehouse quality empty rows do not wait for status counts', (
    tester,
  ) async {
    final api = _DelayedApi(countsOnly: true);
    await _pump(tester, const WarehouseQualityResultsPage(), api);
    await tester.pumpAndSettle();
    final table = tester
        .widget<MasterDataTableView<WarehouseQualityResultTask>>(
          find.byKey(const Key('warehouse-quality-result-table')),
        );
    expect(table.isLoading, isFalse);
    expect(table.items, isEmpty);
    expect(
      api.held.where((path) => path.endsWith('/status-counts')),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'card queues retain their category controls during first loading',
    (tester) async {
      final api = _DelayedApi();
      await _pump(tester, const FinanceArrivalExceptionTasksPage(), api);
      expect(
        find.byKey(const Key('finance-arrival-task-status')),
        findsOneWidget,
      );
      await _pump(
        tester,
        const ProcurementReturnTasksPage(
          orderType: ProcurementInboundOrderType.purchase,
        ),
        api,
      );
      expect(
        find.byKey(const Key('procurement-return-task-segments')),
        findsOneWidget,
      );
      await selectFilterSegment(tester, '历史记录');
      await tester.pump();
      expect(
        find.byKey(const Key('procurement-return-task-segments')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('procurement-return-task-history-time')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _pump(WidgetTester tester, Widget page, _DelayedApi api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.procurementInspectionView,
          Perm.productionQualityInspectionView,
          Perm.productionQualityInspectionApprove,
          Perm.subcontractOrderView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _DelayedApi extends ApiClient {
  _DelayedApi({this.countsOnly = false, this.holdCapability = false})
    : super(Dio(BaseOptions(baseUrl: 'http://localhost/api')));
  final bool countsOnly;
  final bool holdCapability;
  final held = <String>[];

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    if (!countsOnly ||
        path.endsWith('/counts') ||
        (holdCapability && path.endsWith('/capability')) ||
        path.endsWith('/status-counts')) {
      held.add(path);
      return Completer<Map<String, dynamic>>().future;
    }
    return Future.value({
      'items': <Object>[],
      'page': 1,
      'size': 40,
      'total': 0,
      'totalPages': 0,
      'metrics': <Object>[],
    });
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) {
    held.add(path);
    return countsOnly
        ? Future.value([])
        : Completer<List<Map<String, dynamic>>>().future;
  }
}

class _AcceptedThenPendingInbound extends _DelayedApi {
  _AcceptedThenPendingInbound() : super(countsOnly: true);
  int calls = 0;
  final pending = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    if (path != '/warehouse/inbound/expectations') {
      return super.get(path, query: query);
    }
    if (++calls > 1) return pending.future;
    return Future.value({
      'items': [
        {
          'id': 'expectation-1',
          'orderType': 'PURCHASE',
          'orderId': 'order-1',
          'billNo': 'PO-1',
          'supplierId': 'supplier-1',
          'supplierName': '供应商甲',
          'status': 'OPEN',
          'items': <Object>[],
        },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
    });
  }
}

class _DeniedEditorApi extends _DelayedApi {
  _DeniedEditorApi() : super(countsOnly: true);
  int editorReads = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.workshopMaterialMachines &&
        path != ApiEndpoints.goodsPeriodicBomPreparation) {
      return super.get(path, query: query);
    }
    if (++editorReads > 1) {
      throw ApiException('FORBIDDEN', '读取权限已变化', httpStatus: 403);
    }
    return path == ApiEndpoints.workshopMaterialMachines
        ? {
            'machines': [
              {
                'id': 'machine-1',
                'code': 'M1',
                'name': '机台1',
                'containers': <Object>[],
              },
            ],
          }
        : {
            'rows': [
              {
                'productGoodsId': 'product-1',
                'productName': '产品1',
                'materialGoodsId': 'material-1',
                'unitWeightGrams': 20,
                'bomItemId': 'bom-1',
              },
            ],
            'materials': [
              {'goodsId': 'material-1', 'name': '粒料', 'gramsConvertible': true},
            ],
            'totalProducts': 1,
          };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async => {};

  @override
  Future<Map<String, dynamic>> put(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async => {};
}
