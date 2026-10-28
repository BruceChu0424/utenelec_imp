import '../../support/table_read_status.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/features/operations_workbench/pages/operations_workbench_page.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';
import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_CATEGORY_LOADING_CAPTURE');
final _captureKey = GlobalKey();

void main() {
  for (final department in OperationsWorkbenchDepartment.values) {
    testWidgets(
      '${department.name} shows table and time controls before slow responses, and fences obsolete reads',
      (tester) async {
        final (gateway, api) = await _mount(tester, department);
        // The category overview is still pending. A user can already select
        // history and then switch to all dates without waiting for either GET.
        expect(find.text('在上方选择阶段后开始办理'), findsOneWidget);
        await selectFilterSegment(tester, '历史记录');
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(UtenHistoryTimeFilter), findsOneWidget);
        expect(_table(tester).isLoading, isTrue);
        expect(find.text('需求日期'), findsOneWidget);
        final tableElement = tester.element(
          find.byType(MasterDataTableView<OperationsWorkbenchTask>),
        );
        expect(gateway.reads.single.from, isNotNull);

        await selectFilterSegment(tester, '全部');
        await tester.pump(const Duration(milliseconds: 16));
        expect(gateway.reads, hasLength(2));
        expect(gateway.reads.last.from, isNull);
        expect(_table(tester).isLoading, isTrue);
        expect(
          tester.element(
            find.byType(MasterDataTableView<OperationsWorkbenchTask>),
          ),
          same(tableElement),
          reason: 'switching dates keeps the actual table mounted',
        );
        expect(api.dictionaryReads, 0);
        if (_capture && department == OperationsWorkbenchDepartment.purchase) {
          await tester.pump(const Duration(milliseconds: 100));
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'category-loading-purchase-pending',
          );
        }

        gateway.overview.complete(_data(department, oldRow: true));
        gateway.reads.first.result.complete(_data(department, oldRow: true));
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('OBSOLETE-TASK'), findsNothing);
        expect(_table(tester).isLoading, isTrue);

        gateway.reads.last.result.complete(_data(department));
        await tester.pumpAndSettle();
        expect(_table(tester).isLoading, isFalse);
        expect(find.text('当前筛选下没有任务'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(MasterDataTableView<OperationsWorkbenchTask>),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        if (_capture && department == OperationsWorkbenchDepartment.purchase) {
          await tester.pump(const Duration(milliseconds: 100));
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'category-loading-purchase-empty',
          );
        }
        expect(
          api.dictionaryReads,
          0,
          reason: 'an empty table needs no dictionary',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${department.name} empty-query failure keeps filters and retry in the table',
      (tester) async {
        final (gateway, _) = await _mount(tester, department);
        gateway.overview.complete(_data(department));
        await tester.pumpAndSettle();
        await selectFilterSegment(tester, '历史记录');
        gateway.reads.single.result.completeError(NetworkException('任务读取暂时失败'));
        await tester.pumpAndSettle();
        expect(find.byType(UtenHistoryTimeFilter), findsOneWidget);
        expect(find.text('需求日期'), findsOneWidget);
        await expectTableReadFailureDetails(tester, '任务读取暂时失败');
        expect(find.text('当前筛选下没有任务'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('master-table-initial-read-retry')),
        );
        await tester.pump();
        expect(gateway.reads, hasLength(2));
        expect(_table(tester).isLoading, isTrue);
        gateway.reads.last.result.complete(_data(department));
        await tester.pumpAndSettle();
        expect(find.text('当前筛选下没有任务'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

MasterDataTableView<OperationsWorkbenchTask> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<OperationsWorkbenchTask>));

Future<(_Gateway, _Api)> _mount(
  WidgetTester tester,
  OperationsWorkbenchDepartment department,
) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if (_capture) await loadAuditScreenshotFonts(tester);
  final gateway = _Gateway();
  final api = _Api();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: _capture ? auditScreenshotTheme(buildLightTheme()) : null,
        home: Builder(
          builder: (_) {
            final page = OperationsWorkbenchPage(
              department: department,
              repository: gateway,
            );
            return _capture
                ? RepaintBoundary(key: _captureKey, child: page)
                : page;
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return (gateway, api);
}

OperationsWorkbenchData _data(
  OperationsWorkbenchDepartment department, {
  bool oldRow = false,
}) => OperationsWorkbenchData(
  department: department,
  summary: const OperationsWorkbenchSummary(
    totalTasks: 0,
    overdueTasks: 0,
    openTasks: 0,
    openQty: 0,
    statusCounts: {},
  ),
  items: [
    if (oldRow)
      OperationsWorkbenchTask.fromJson({
        'taskId': 'obsolete',
        'supplyRoute': 'PURCHASE',
        'taskStatus': 'COMPLETED',
        'goodsName': 'OBSOLETE-TASK',
      }, department),
  ],
  page: 1,
  size: 50,
  total: oldRow ? 1 : 0,
  totalPages: oldRow ? 1 : 0,
  capabilities: const OperationsWorkbenchCapabilities(),
);

class _Gateway
    implements OperationsWorkbenchGateway, OperationsWorkbenchOverviewGateway {
  final overview = Completer<OperationsWorkbenchData>();
  final reads = <({String? from, Completer<OperationsWorkbenchData> result})>[];

  @override
  Future<OperationsWorkbenchData> loadOverview({
    required OperationsWorkbenchDepartment department,
    String? keyword,
  }) => overview.future;

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
  }) {
    final result = Completer<OperationsWorkbenchData>();
    reads.add((from: dateFrom, result: result));
    return result.future;
  }
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  int dictionaryReads = 0;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    dictionaryReads++;
    return [];
  }
}
