import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/audit_screenshot_support.dart';

void main() {
  for (final scenario in [
    (
      name: 'desktop-light',
      size: const Size(1600, 900),
      dark: false,
      scale: 1.0,
    ),
    (name: 'medium-dark', size: const Size(760, 900), dark: true, scale: 1.0),
    (
      name: 'compact-large-text',
      size: const Size(390, 844),
      dark: false,
      scale: 2.0,
    ),
  ]) {
    testWidgets(
      '${scenario.name} shows request difference and forwards exact server sort',
      (tester) async {
        const capture = bool.fromEnvironment('UTEN_AUDIT_SCREENSHOTS');
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (capture) await loadAuditScreenshotFonts(tester);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final gateway = _Gateway();
        final captureKey = GlobalKey();
        final theme = scenario.dark ? buildDarkTheme() : buildLightTheme();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              apiClientProvider.overrideWithValue(_Api()),
              fixedBadgeSummaryOverride(
                badgeSummaryFixture(
                  facts: const {BadgeFact.purchaseTaskWaitingOrder: 4},
                ),
              ),
            ],
            child: RepaintBoundary(
              key: captureKey,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh'),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                theme: capture ? auditScreenshotTheme(theme) : theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scenario.scale),
                    disableAnimations: true,
                  ),
                  child: child!,
                ),
                home: OperationsWorkbenchPage(
                  department: OperationsWorkbenchDepartment.purchase,
                  repository: gateway,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tableFinder = find.byType(
          MasterDataTableView<OperationsWorkbenchTask>,
        );
        final table = tester
            .widget<MasterDataTableView<OperationsWorkbenchTask>>(tableFinder);
        final column = table.columns.singleWhere(
          (column) => column.key == 'differenceQty',
        );
        expect(column.value(table.items[0]), '-8 个');
        expect(column.value(table.items[1]), '0 个');
        expect(column.value(table.items[2]), '2.5 个');
        expect(column.value(table.items[3]), '—');
        expect(column.exactValueOf!(table.items[0]), '-8.0000');
        expect(column.info, contains('尚未下单'));
        expect(column.info, contains('未到齐'));
        expect(column.filterFromRows, isFalse);
        for (final hidden in [
          {'actionDocRestricted': true},
          {'goodsCount': 2, 'openLineCount': 2},
        ]) {
          final task = OperationsWorkbenchTask.fromJson({
            'taskId': 'unavailable-comparison',
            'supplyRoute': 'BUY',
            'taskStatus': 'WAITING_ORDER',
            'differenceQtyExact': '-8',
            'unitName': '个',
            ...hidden,
          }, OperationsWorkbenchDepartment.purchase);
          expect(column.value(task), '—');
          expect(column.exactValueOf!(task), isNull);
        }
        final context = tester.element(tableFinder);
        final negative = column.cellBuilder!(context, table.items[0]) as Text;
        expect(negative.style?.color, Theme.of(context).colorScheme.error);
        table.onSortChange!('differenceQty', true);
        await tester.pumpAndSettle();
        expect(gateway.sort, 'differenceQty');
        expect(gateway.order, 'asc');
        final export = tester.widget<UtenExportButton>(
          find.byKey(const Key('purchase-workbench-export')),
        );
        expect(export.queryParams['sort'], 'differenceQty');
        expect(export.queryParams['order'], 'asc');
        await tester.ensureVisible(find.text('-8 个').first);
        await tester.pumpAndSettle();
        if (capture) {
          await saveAuditScreenshot(
            tester,
            captureKey,
            'procurement-difference-${scenario.name}',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'items': <Object?>[]};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

class _Gateway implements OperationsWorkbenchGateway {
  String? sort;
  String? order;
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
    this.sort = sort;
    this.order = order;
    return OperationsWorkbenchData(
      department: department,
      summary: const OperationsWorkbenchSummary(
        totalTasks: 4,
        overdueTasks: 0,
        openTasks: 4,
        openQty: 8,
        statusCounts: {'WAITING_ORDER': 4},
      ),
      items: [
        for (final entry in ['-8.0000', '0.0000', '2.5000', null].indexed)
          OperationsWorkbenchTask.fromJson({
            'taskId': 'request-item-${entry.$1}',
            'supplyRoute': 'BUY',
            'taskStatus': 'WAITING_ORDER',
            'requiredQty': 8,
            'allocatedQty': [0, 8, 10.5, 0][entry.$1],
            'fulfilledQty': [0, 8, 10.5, 0][entry.$1],
            'openQty': [8, 0, 0, 8][entry.$1],
            'goodsName': ['未下单物料', '已全部下单', '超量下单', '旧响应未知量'][entry.$1],
            'goodsCode': 'GD00${entry.$1}',
            'unitName': '个',
            'planNo': 'WL-20261027',
            'actionDocType': 'PURCHASE_REQUEST',
            'actionDocId': 'request-1',
            'actionDocNo': 'CGSQ-001',
            'actionDocCanView': true,
            'actionDocItemId': 'request-item-${entry.$1}',
            'differenceQtyExact': entry.$2,
          }, department),
      ],
      page: page,
      size: size,
      total: 4,
      totalPages: 1,
      capabilities: const OperationsWorkbenchCapabilities(),
    );
  }
}
