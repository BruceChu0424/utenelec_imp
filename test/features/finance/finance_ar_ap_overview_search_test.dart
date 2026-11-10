import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_overview_page.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/widgets/finance_date_range_filter.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/native_detail_reader_overrides.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
  });

  testWidgets(
    'default customer report keeps the old 16 headers and exports the same scope',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      final capture = GlobalKey();
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(),
        capture: capture,
      );
      expect(
        api.reportQueries.last,
        containsPair('layout', 'RECEIVABLE_SUMMARY'),
      );
      expect(api.reportQueries.last, containsPair('categoryType', 'CLIENT'));
      expect(_tree(tester).selectedIds, {'__client_root__'});
      expect(
        _table(tester).columns.map((column) => column.label),
        _summaryLabels,
      );
      expect(_table(tester).tableKey, endsWith('.receivableSummary.v1'));
      expect(
        _table(
          tester,
        ).columns.singleWhere((column) => column.key == 'materialAmount').info,
        contains('待核验'),
      );
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams, containsPair('layout', 'RECEIVABLE_SUMMARY'));
      expect(export.queryParams, containsPair('categoryType', 'CLIENT'));
      expect(export.filename, '应收款汇总表');
      if (const bool.fromEnvironment('UI_CAPTURE')) {
        await _captureOverview(tester, capture, 'summary-16-columns');
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'customer summary search retains its schema and searches beyond selected category',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(
          docType: 'CLIENT',
          extra: {'categoryId': 'overseas'},
        ),
      );
      expect(api.reportQueries.last['categoryId'], 'overseas');
      await tester.enterText(_searchField(), 'C-003');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      _expectGlobal(api.reportQueries.last, 'C-003');
      expect(api.reportQueries.last['layout'], 'RECEIVABLE_SUMMARY');
      expect(
        _table(tester).columns.map((column) => column.label),
        _summaryLabels,
      );
      expect(
        _tree(tester).visibleFilterIds,
        isNot(contains('domestic-supplier')),
      );
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams['layout'], 'RECEIVABLE_SUMMARY');
      expect(
        export.bodyParams['sensitiveFilter'],
        containsPair('keyword', 'C-003'),
      );
      await tester.enterText(_searchField(), '');
      await tester.pumpAndSettle();
      expect(api.reportQueries.last['categoryId'], 'overseas');
      expect(_tree(tester).selectedIds, {'overseas'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'schema switches retire old results and clear incompatible column criteria',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(),
      );
      _table(tester).onFilterChanged('search.creditFloor', '100');
      await tester.pumpAndSettle();
      _table(tester).onSortChange!('balance', false);
      await tester.pumpAndSettle();
      api.holdNextReport();
      _table(tester).onSortChange!('balance', true);
      await tester.pump();
      expect(api.heldReport, isNotNull);
      _tree(tester).onNodeTap!(_tree(tester).nodes.last);
      await tester.pumpAndSettle();
      expect(api.reportQueries.last['layout'], 'BALANCE');
      expect(api.reportQueries.last['categoryType'], 'SUPPLIER');
      expect(api.reportQueries.last, isNot(contains('f.search.creditFloor')));
      expect(api.reportQueries.last, isNot(contains('sort')));
      expect(_table(tester).tableKey, isNot(endsWith('.receivableSummary.v1')));
      api.completeHeldReport('stale-summary-after-supplier-switch');
      await tester.pumpAndSettle();
      expect(find.text('stale-summary-after-supplier-switch'), findsNothing);
      expect(_table(tester).columns.map((column) => column.label), ['往来单位']);
      _tree(tester).onNodeTap!(_tree(tester).nodes.first);
      await tester.pumpAndSettle();
      expect(api.reportQueries.last['layout'], 'RECEIVABLE_SUMMARY');
      expect(
        _table(tester).columns.map((column) => column.label),
        _summaryLabels,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old customer preferences migrate incompatible sort and display to summary',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(
          docType: 'CLIENT',
          sortKey: 'receivable',
          extra: {'displayMode': 'ANY'},
        ),
      );
      expect(api.reportQueries.last['layout'], 'RECEIVABLE_SUMMARY');
      expect(api.reportQueries.last['displayMode'], 'AR_ONLY');
      expect(api.reportQueries.last, isNot(contains('sort')));
      await tester.tap(find.byKey(const ValueKey('finance-ar-ap-layout')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('往来余额').last);
      await tester.pumpAndSettle();
      expect(api.reportQueries.last['layout'], 'BALANCE');
      expect(api.reportQueries.last, isNot(contains('categoryType')));
      final context = tester.element(find.byType(FinanceArApOverviewPage));
      final saved = ProviderScope.containerOf(
        context,
      ).read(financeArApOverviewReportPrefsProvider);
      expect(saved.extra['layout'], 'BALANCE');
      expect(saved.docType, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '2500 customer rows append progressively and enable output only when complete',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi()
        ..largeSummaryTotal = 2500
        ..largeSummaryGate = Completer<void>();
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(),
        settle: false,
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_table(tester).items, hasLength(50));
      expect(_table(tester).loadingMore, isTrue);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(
        tester.widget<UtenExportButton>(find.byType(UtenExportButton)).enabled,
        isFalse,
      );
      expect(
        tester
            .widget<UtenPrintPreviewButton>(find.byType(UtenPrintPreviewButton))
            .enabled,
        isFalse,
      );
      final tableState = tester.state(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      api.largeSummaryGate!.complete();
      await tester.pumpAndSettle();
      final rows = _table(tester).items;
      expect(rows, hasLength(2500));
      expect(rows.map((row) => row['id']).toSet(), hasLength(2500));
      expect(rows.first['id'], 'summary-client-0');
      expect(rows.last['id'], 'summary-client-2499');
      expect(api.reportQueries.map((query) => query['size']), contains(1000));
      expect(
        tester.state(find.byType(MasterDataTableView<Map<String, dynamic>>)),
        same(tableState),
      );
      expect(
        tester.widget<UtenExportButton>(find.byType(UtenExportButton)).enabled,
        isTrue,
      );
      expect(_table(tester).loadingMore, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid layout changes and search retire a growing customer prefix during debounce',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi()
        ..largeSummaryTotal = 1500
        ..largeSummaryGate = Completer<void>();
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(),
        settle: false,
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_table(tester).items, hasLength(50));
      _tree(tester).onNodeTap!(_tree(tester).nodes.last);
      await tester.pumpAndSettle();
      expect(api.reportQueries.last['layout'], 'BALANCE');
      _tree(tester).onNodeTap!(_tree(tester).nodes.first);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(_table(tester).items, hasLength(50));
      await tester.enterText(_searchField(), 'C-003');
      await tester.pump();
      expect(
        find.text('summary-row-0'),
        findsNothing,
        reason: 'retire before the search debounce fires',
      );
      for (final table
          in tester.widgetList<MasterDataTableView<Map<String, dynamic>>>(
            find.byType(MasterDataTableView<Map<String, dynamic>>),
          )) {
        expect(
          table.items,
          isEmpty,
          reason: 'no old prefix may survive in a retained shell',
        );
      }
      for (final export in tester.widgetList<UtenExportButton>(
        find.byType(UtenExportButton),
      )) {
        expect(
          export.enabled,
          isFalse,
          reason: 'a retired prefix is never an output scope',
        );
      }
      expect(find.text('共 1500'), findsNothing);
      final readsBeforeRelease = api.reportQueries.length;
      api.largeSummaryGate!.complete();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.reportQueries.length, readsBeforeRelease + 1);
      expect(api.reportQueries.last['keyword'], 'C-003');
      expect(_table(tester).items.single['partyName'], 'latest-C-003');
      expect(find.text('summary-row-0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed growing read withdraws every partial customer row', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi()
      ..largeSummaryTotal = 1500
      ..largeSummaryGate = Completer<void>();
    await _pumpPage(
      tester,
      prefs: prefs,
      api: api,
      initialPrefs: const ReportFilterPrefs(),
      settle: false,
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(_table(tester).items, hasLength(50));
    api.largeSummaryGate!.completeError(
      StateError('interrupted summary transport'),
    );
    await tester.pumpAndSettle();
    expect(find.text('summary-row-0'), findsNothing);
    expect(find.byType(UtenExportButton), findsNothing);
    expect(find.text('重试'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real ARAP return clears its search, stops the old locator and refreshes only the current query',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi()
        ..largeLocator = true
        ..locationGate = Completer<Map<String, dynamic>>();
      final router = GoRouter(
        initialLocation: RouteName.financeReportOverview,
        routes: [
          GoRoute(
            path: RouteName.financeReportOverview,
            builder: (_, _) => const FinanceArApOverviewPage(),
          ),
          GoRoute(
            path: '/cover',
            builder: (_, _) => const Scaffold(body: Text('opaque cover')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pumpPage(tester, prefs: prefs, api: api, router: router);
      await tester.enterText(_searchField(), 'C-003');
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(api.locationReads, [(0, 1), (0, 2)]);
      unawaited(router.push<void>('/cover'));
      await tester.pumpAndSettle();
      expect(api.locationActivity.last!(), isFalse);
      api.locationGate!.complete({
        'items': [
          {'partyType': 'CLIENT', 'categoryId': null},
        ],
        'page': 2,
        'size': 100,
        'total': 3,
        'totalPages': 3,
      });
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(api.locationReads, [(0, 1), (0, 2)]);
      final reports = api.reportQueries.length;
      api.locatorRevision = 1;
      router.pop();
      await tester.pumpAndSettle();
      expect(api.locationReads, [(0, 1), (0, 2)]);
      expect(api.reportQueries.length, reports + 1);
      expect(api.reportActivityAtDispatch, everyElement(isTrue));
      expect(api.reportQueries.last, isNot(contains('keyword')));
      expect(
        tester.widget<TextField>(_searchField()).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Ticker-only ARAP cover retains the query and revalidates report and full locator once',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final api = _OverviewApi()
        ..largeLocator = true
        ..locationGate = Completer<Map<String, dynamic>>();
      await _pumpPage(tester, prefs: prefs, api: api, active: active);
      await tester.enterText(_searchField(), 'C-003');
      await tester.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(api.locationReads, [(0, 1), (0, 2)]);
      active.value = false;
      await tester.pump();
      expect(api.locationActivity.last!(), isFalse);
      api.locationGate!.complete({
        'items': [
          {'partyType': 'CLIENT', 'categoryId': null},
        ],
        'page': 2,
        'size': 100,
        'total': 3,
        'totalPages': 3,
      });
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(api.locationReads, [(0, 1), (0, 2)]);
      final reports = api.reportQueries.length;
      api.locatorRevision = 1;
      active.value = true;
      await tester.pumpAndSettle();
      expect(api.locationReads, [(0, 1), (0, 2), (1, 1), (1, 2), (1, 3)]);
      expect(api.reportQueries.length, reports + 1);
      expect(api.reportQueries.last['keyword'], 'C-003');
      expect(_tree(tester).visibleFilterIds, contains('domestic-supplier'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('finance report return preserves hub scroll and report filters', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi();
    final router = GoRouter(
      initialLocation: RouteName.finance,
      routes: [
        GoRoute(
          path: RouteName.finance,
          builder: (_, _) => const FinanceHubPage(),
        ),
        GoRoute(
          path: RouteName.financeReportOverview,
          builder: (_, _) => const FinanceArApOverviewPage(),
        ),
        GoRoute(
          path: '/finance/test-detail',
          builder: (_, _) => Scaffold(
            appBar: AppBar(leading: const UtenBackButton()),
            body: const Text('report detail'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await _pumpPage(
      tester,
      prefs: prefs,
      api: api,
      router: router,
      size: const Size(1000, 700),
    );
    final hubState = tester.state(find.byType(FinanceHubPage));
    final hubList = find.byKey(const PageStorageKey('finance-hub-scroll'));
    final hubScrollable = find.descendant(
      of: hubList,
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('应收应付'),
      400,
      scrollable: hubScrollable,
    );
    await tester.pumpAndSettle();
    final offset = tester.state<ScrollableState>(hubScrollable).position.pixels;
    expect(offset, greaterThan(0));
    await tester.tap(find.text('应收应付'));
    await tester.pumpAndSettle();
    expect(router.canPop(), isTrue);
    expect(router.state.uri.queryParameters['returnTo'], RouteName.finance);
    final reportState = tester.state(find.byType(FinanceArApOverviewPage));
    await tester.tap(find.byType(FinanceDateRangeFilter));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(UtenDateRangePickerDialog),
        matching: find.text('10'),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(UtenDateRangePickerDialog),
        matching: find.text('20'),
      ),
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('finance-ar-ap-display-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('只应付≠0').last);
    await tester.pumpAndSettle();
    final filtered = Map<String, dynamic>.of(api.reportQueries.last);
    expect(filtered['displayMode'], 'AP_ONLY');
    final dates = tester.widget<FinanceDateRangeFilter>(
      find.byType(FinanceDateRangeFilter),
    );
    unawaited(router.push<void>('/finance/test-detail'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(UtenBackButton),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.state(find.byType(FinanceArApOverviewPage)),
      same(reportState),
    );
    final restoredDates = tester.widget<FinanceDateRangeFilter>(
      find.byType(FinanceDateRangeFilter),
    );
    expect(restoredDates.from, dates.from);
    expect(restoredDates.to, dates.to);
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('finance-ar-ap-display-mode')),
          )
          .value,
      'AP_ONLY',
    );
    for (final field in ['dateFrom', 'dateTo', 'displayMode']) {
      expect(api.reportQueries.last[field], filtered[field], reason: field);
    }
    await tester.tap(
      find.descendant(
        of: find.byType(UtenBackButton),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(FinanceHubPage)), same(hubState));
    expect(
      tester.state<ScrollableState>(hubScrollable).position.pixels,
      closeTo(offset, 0.1),
    );
    // Framework back must use the same preserved source page as the page button.
    await tester.tap(find.text('应收应付'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(FinanceHubPage)), same(hubState));
    expect(
      tester.state<ScrollableState>(hubScrollable).position.pixels,
      closeTo(offset, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hub report row opens native document and returns through both retained pages',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      final router = GoRouter(
        initialLocation: RouteName.finance,
        routes: [
          GoRoute(
            path: RouteName.finance,
            builder: (_, _) => const FinanceHubPage(),
          ),
          GoRoute(
            path: RouteName.financeReportDetail,
            builder: (_, _) => const FinanceReportTablePage(cardId: 'detail'),
          ),
          GoRoute(
            path: '/finance/receipts/:id',
            builder: (_, state) => FinanceDocDetailPage(
              docType: FinanceDocType.receipt,
              id: state.pathParameters['id']!,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        router: router,
        size: const Size(1920, 600),
        readFinanceDetail: true,
      );
      final hubState = tester.state(find.byType(FinanceHubPage));
      final hubScrollable = find.descendant(
        of: find.byKey(const PageStorageKey('finance-hub-scroll')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.text('明细报表'),
        400,
        scrollable: hubScrollable,
      );
      await tester.pumpAndSettle();
      final offset = tester
          .state<ScrollableState>(hubScrollable)
          .position
          .pixels;
      expect(offset, greaterThan(0));
      await tester.tap(find.text('明细报表'));
      await tester.pumpAndSettle();
      final reportState = tester.state(find.byType(FinanceReportTablePage));
      await tester.tap(find.text('销售收款明细'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FinanceDateRangeFilter));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenDateRangePickerDialog),
          matching: find.text('10'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(UtenDateRangePickerDialog),
          matching: find.text('20'),
        ),
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      final dates = tester.widget<FinanceDateRangeFilter>(
        find.byType(FinanceDateRangeFilter),
      );
      // Browse tables select on one click and open on two clicks.
      await tester.tap(find.text('RECEIPT-001'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('RECEIPT-001'));
      await tester.pumpAndSettle();
      expect(find.byType(FinanceDocDetailPage), findsOneWidget);
      expect(find.text('SK-20261021-001'), findsOneWidget);
      expect(router.canPop(), isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(UtenBackButton),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byType(FinanceReportTablePage)),
        same(reportState),
      );
      final restored = tester.widget<FinanceDateRangeFilter>(
        find.byType(FinanceDateRangeFilter),
      );
      expect(restored.from, dates.from);
      expect(restored.to, dates.to);
      expect(find.text('RECEIPT-001'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(UtenBackButton),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(FinanceHubPage)), same(hubState));
      expect(
        tester.state<ScrollableState>(hubScrollable).position.pixels,
        closeTo(offset, 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'overview tree and single toolbar fit desktop narrow zoom and dark',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      for (final variant in [
        (size: const Size(1600, 1000), scale: 1.0, dark: false),
        (size: const Size(900, 900), scale: 2.0, dark: false),
        (size: const Size(360, 800), scale: 2.0, dark: true),
        (size: const Size(844, 390), scale: 1.5, dark: true),
      ]) {
        final capture = GlobalKey();
        final api = _OverviewApi();
        await _pumpPage(
          tester,
          prefs: prefs,
          api: api,
          size: variant.size,
          scale: variant.scale,
          dark: variant.dark,
          capture: capture,
          initialPrefs: const ReportFilterPrefs(),
        );
        expect(tester.takeException(), isNull, reason: '$variant');
        expect(find.textContaining('应收应付 ·'), findsNothing);
        expect(find.byType(FinanceDateRangeFilter), findsOneWidget);
        expect(_table(tester).toolbarLeadingActions, hasLength(4));
        expect(
          _table(tester).columns.map((column) => column.label),
          _summaryLabels,
        );
        if (variant.size.width >= 840) {
          expect(_tree(tester).flatLevelColors, isTrue);
        }
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await _captureOverview(
            tester,
            capture,
            '${variant.size.width.toInt()}-${variant.scale}',
          );
        }
        // The shared table bounds tall toolbars and scrolls their controls.
        // Verify the later filters are reachable at 200%, not merely mounted.
        final mode = find.byKey(const ValueKey('finance-ar-ap-display-mode'));
        await tester.ensureVisible(mode);
        await tester.pumpAndSettle();
        expect(mode.hitTestable(), findsOneWidget);
        await tester.tap(mode);
        await tester.pumpAndSettle();
        await tester.tap(find.text('只应收≠0').last);
        await tester.pumpAndSettle();
        expect(api.reportQueries.last['displayMode'], 'AR_ONLY');
        final count = find.text('共 1');
        await tester.ensureVisible(count);
        await tester.pumpAndSettle();
        expect(count.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$variant filters');
        if (const bool.fromEnvironment('UI_CAPTURE')) {
          await _captureOverview(
            tester,
            capture,
            '${variant.size.width.toInt()}-${variant.scale}-filters',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'one global table combines categories and preserves server exact-before-near order',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      final baseline = Map<String, dynamic>.of(api.reportQueries.last);
      await tester.enterText(_searchField(), 'C-002');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        api.locationQueries
            .where((query) => query['keyword'] == 'C-002')
            .map((query) => query['page']),
        [1, 2],
      );
      expect(
        _tree(tester).visibleFilterIds,
        containsAll(<String>{
          '__client_root__',
          'overseas',
          'southeast-asia',
          '__supplier_root__',
          'domestic-supplier',
        }),
      );
      expect(_tree(tester).selectedIds, isEmpty);
      expect(_table(tester).items.map((row) => row['partyName']), [
        'EXACT-C-002',
        'PREFIX-C-002',
        'NEAR-C-002',
        'PAGE2-C-002',
      ]);
      expect(_table(tester).items.map((row) => row['categoryId']).toSet(), {
        'southeast-asia',
        'domestic-supplier',
        'overseas',
      });
      expect(_table(tester).totalPages, 1);
      expect(find.text('共 4'), findsOneWidget);
      expect(find.textContaining('应收应付 ·'), findsNothing);
      expect(_tree(tester).flatLevelColors, isTrue);
      _expectGlobal(api.reportQueries.last, 'C-002');
      expect(api.reportSearchRequests, isNotEmpty);
      expect(api.reportSearchRequests.last.query, isNot(contains('keyword')));
      expect(api.reportSearchRequests.last.body['keyword'], 'C-002');
      expect(api.reportQueries.last['dateFrom'], baseline['dateFrom']);
      expect(api.reportQueries.last['dateTo'], baseline['dateTo']);
      await tester.tap(find.textContaining('海外客户'));
      await tester.pumpAndSettle();
      _expectGlobal(api.reportQueries.last, 'C-002');
      expect(_table(tester).items, hasLength(4));
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(export.queryParams, isNot(contains('keyword')));
      expect(export.queryParams, isNot(contains('categoryType')));
      expect(export.queryParams, isNot(contains('categoryId')));
      expect(
        export.bodyParams['sensitiveFilter'],
        containsPair('keyword', 'C-002'),
      );
      final loadedReads = api.reportQueries.length;
      final scroll = find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      );
      await tester.drag(scroll.last, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(api.reportQueries.length, loadedReads);
      _expectGlobal(api.reportQueries.last, 'C-002');
      expect(_table(tester).items.last['partyName'], 'PAGE2-C-002');
      final beforeSort = api.reportQueries.length;
      _table(tester).onSortChange!('arAmount', false);
      await tester.pumpAndSettle();
      expect(api.reportQueries.last, containsPair('sort', 'arAmount'));
      expect(api.reportQueries.last, containsPair('order', 'desc'));
      final sortedFirstPage = api.reportQueries
          .skip(beforeSort)
          .firstWhere((query) => query['page'] == 1);
      expect(sortedFirstPage['includeCount'], isNull);
      _expectGlobal(api.reportQueries.last, 'C-002');
    },
  );

  testWidgets(
    'a category code is retained as the keyword without selecting that branch',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      await tester.enterText(_searchField(), 'SEA-001');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(_tree(tester).selectedIds, isEmpty);
      expect(_tree(tester).visibleFilterIds, contains('southeast-asia'));
      _expectGlobal(api.reportQueries.last, 'SEA-001');
      expect(find.text('latest-SEA-001'), findsOneWidget);
    },
  );

  testWidgets(
    'clearing a search restores original type and category while keeping date display and sort',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi(delayLocationKeyword: 'OVER');
      await _pumpPage(
        tester,
        prefs: prefs,
        api: api,
        initialPrefs: const ReportFilterPrefs(
          docType: 'SUPPLIER',
          sortKey: 'arAmount',
          sortAsc: false,
          extra: {'categoryId': 'domestic-supplier', 'displayMode': 'AP_ONLY'},
        ),
      );
      final before = Map<String, dynamic>.of(api.reportQueries.last);
      expect(before['categoryType'], 'SUPPLIER');
      expect(before['categoryId'], 'domestic-supplier');
      await tester.enterText(_searchField(), 'OVER');
      await tester.pump(const Duration(milliseconds: 320));
      await tester.tap(find.textContaining('海外客户'));
      await tester.pump(const Duration(milliseconds: 600));
      _expectGlobal(api.reportQueries.last, 'OVER');
      expect(_tree(tester).selectedIds, isEmpty);
      await tester.enterText(_searchField(), '');
      api.heldLocationDelay!.complete();
      await tester.pumpAndSettle();
      expect(
        api.reportQueries.last,
        allOf(
          containsPair('categoryType', 'SUPPLIER'),
          containsPair('categoryId', 'domestic-supplier'),
        ),
      );
      expect(api.reportQueries.last, isNot(contains('keyword')));
      for (final field in [
        'dateFrom',
        'dateTo',
        'displayMode',
        'sort',
        'order',
      ]) {
        expect(api.reportQueries.last[field], before[field], reason: field);
      }
      expect(_tree(tester).selectedIds, {'domestic-supplier'});
      expect(find.textContaining('应收应付 ·'), findsNothing);
    },
  );

  testWidgets('stale report response cannot replace the latest global search', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi(delayFirstSearch: true);
    await _pumpPage(tester, prefs: prefs, api: api);
    await tester.enterText(_searchField(), 'C-002');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.enterText(_searchField(), 'C-003');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('latest-C-003'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('stale-C-002'), findsNothing);
    expect(find.text('latest-C-003'), findsOneWidget);
    expect(_tree(tester).selectedIds, isEmpty);
    _expectGlobal(api.reportQueries.last, 'C-003');
  });

  testWidgets(
    'server empty search result does not fall back to unfiltered rows',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      final before = api.reportQueries.length;
      await tester.enterText(_searchField(), 'NO-SUCH-PARTY');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('未找到匹配「NO-SUCH-PARTY」的分类或往来单位'), findsOneWidget);
      expect(api.reportQueries.length, before + 1);
      _expectGlobal(api.reportQueries.last, 'NO-SUCH-PARTY');
      expect(_table(tester).items, isEmpty);
      expect(find.text('initial'), findsNothing);
    },
  );

  testWidgets(
    'failed category hints do not block global results or restore a superseded report',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final api = _OverviewApi();
      await _pumpPage(tester, prefs: prefs, api: api);
      api.holdNextReport();
      await tester.tap(
        find.byKey(const ValueKey('finance-ar-ap-display-mode')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('只应收≠0').last);
      await tester.pump();
      expect(api.heldReport, isNotNull);
      await tester.enterText(_searchField(), 'LOCATOR-FAIL');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.textContaining('分类定位暂不可用'), findsOneWidget);
      expect(find.text('latest-LOCATOR-FAIL'), findsOneWidget);
      _expectGlobal(api.reportQueries.last, 'LOCATOR-FAIL');
      expect(api.reportQueries.last['displayMode'], 'AR_ONLY');
      expect(_table(tester).isLoading, isFalse);
      api.completeHeldReport('stale-held-report');
      await tester.pump();
      expect(find.text('stale-held-report'), findsNothing);
      expect(find.text('latest-LOCATOR-FAIL'), findsOneWidget);
    },
  );

  testWidgets('new input invalidates old report during the debounce window', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _OverviewApi();
    await _pumpPage(tester, prefs: prefs, api: api);
    api.holdNextReport();
    await tester.enterText(_searchField(), 'C-002');
    await tester.pump(const Duration(milliseconds: 350));
    expect(api.heldReport, isNotNull);
    await tester.enterText(_searchField(), 'C-003');
    await tester.pump();
    api.completeHeldReport('stale-in-debounce');
    await tester.pump();
    expect(find.text('stale-in-debounce'), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('latest-C-003'), findsOneWidget);
  });
}

Finder _searchField() => find.descendant(
  of: find.byKey(const ValueKey('finance-ar-ap-unified-search')),
  matching: find.byType(TextField),
);
MasterDataTableView<Map<String, dynamic>> _table(WidgetTester tester) =>
    tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
UtenCategoryTreeView<ProductCategoryNode> _tree(WidgetTester tester) =>
    tester.widget(find.byType(UtenCategoryTreeView<ProductCategoryNode>));
void _expectGlobal(Map<String, dynamic> query, String keyword) {
  expect(query['keyword'], keyword);
  expect(query, isNot(contains('categoryType')));
  expect(query, isNot(contains('categoryId')));
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required _OverviewApi api,
  // These original regressions exercise the cross-party balance view. Default
  // summary behavior has separate cases above and never relies on this fixture.
  ReportFilterPrefs initialPrefs = const ReportFilterPrefs(
    extra: {'layout': 'BALANCE'},
  ),
  GoRouter? router,
  Size size = const Size(1600, 1000),
  double scale = 1,
  bool dark = false,
  GlobalKey? capture,
  bool readFinanceDetail = false,
  ValueNotifier<bool>? active,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(true),
        if (!readFinanceDetail)
          authenticatedScopeProvider.overrideWithValue(null),
        if (readFinanceDetail)
          ...nativeDetailReaderOverrides(includeBadge: false),
        fixedBadgeSummaryOverride(),
        financeDetailReportPrefsProvider.overrideWith(_FixedDetailPrefs.new),
        financeArApOverviewReportPrefsProvider.overrideWith(
          () => _FixedPrefs(initialPrefs),
        ),
        clientCategoryRepositoryProvider.overrideWithValue(
          _ClientCategoryRepo(),
        ),
        supplierCategoryRepositoryProvider.overrideWithValue(
          _SupplierCategoryRepo(),
        ),
      ],
      child: RepaintBoundary(
        key: capture,
        child: router == null
            ? MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: active == null
                    ? const FinanceArApOverviewPage()
                    : ValueListenableBuilder<bool>(
                        valueListenable: active,
                        child: const FinanceArApOverviewPage(),
                        builder: (_, enabled, child) =>
                            TickerMode(enabled: enabled, child: child!),
                      ),
              )
            : MaterialApp.router(
                routerConfig: router,
                theme: buildLightTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
              ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Future<void> _captureOverview(
  WidgetTester tester,
  GlobalKey capture,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final rendered = await boundary.toImage();
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory('output/finance-redesign/previews');
    await folder.create(recursive: true);
    await File(
      '${folder.path}/overview-$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    rendered.dispose();
  });
}

class _FixedPrefs extends FinanceArApOverviewReportPrefsNotifier {
  _FixedPrefs(this.initial);
  final ReportFilterPrefs initial;
  @override
  ReportFilterPrefs build() => initial;
  @override
  void update(ReportFilterPrefs value) => state = value;
}

class _FixedDetailPrefs extends FinanceDetailReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs();
  @override
  void update(ReportFilterPrefs value) => state = value;
}

class _OverviewApi extends ApiClient {
  _OverviewApi({this.delayFirstSearch = false, this.delayLocationKeyword})
    : super(Dio());

  final bool delayFirstSearch;
  final String? delayLocationKeyword;
  Completer<void>? heldLocationDelay;
  // Business criteria stay flat in this fake; private wire requests are
  // captured separately so tests can verify contact values never enter URLs.
  final reportQueries = <Map<String, dynamic>>[];
  final reportActivityAtDispatch = <bool>[];
  final reportSearchRequests =
      <({Map<String, dynamic> query, Map<String, dynamic> body})>[];
  final locationQueries = <Map<String, dynamic>>[];
  bool largeLocator = false;
  int locatorRevision = 0;
  final locationReads = <(int, int)>[];
  final locationActivity = <bool Function()?>[];
  Completer<Map<String, dynamic>>? locationGate;

  bool _holdNextReport = false;
  Completer<Map<String, dynamic>>? heldReport;
  Map<String, dynamic>? _heldQuery;
  int largeSummaryTotal = 0;
  Completer<void>? largeSummaryGate;

  void holdNextReport() => _holdNextReport = true;

  void completeHeldReport(String label) {
    final held = heldReport;
    if (held == null || held.isCompleted) return;
    held.complete(_forLayout(_heldQuery ?? const {}, _report(label)));
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path != '/finance/reports/ar-ap/overview/search') {
      return super.post(path, body: body, headers: headers, query: query);
    }
    expect(
      query,
      isNot(contains('keyword')),
      reason: 'contact keyword belongs only in the private POST body',
    );
    expect(body, isA<Map<String, dynamic>>());
    final wireQuery = Map<String, dynamic>.from(query ?? const {});
    final wireBody = Map<String, dynamic>.from(body! as Map<Object?, Object?>);
    reportSearchRequests.add((query: wireQuery, body: wireBody));
    return get(
      '/finance/reports/ar-ap/overview',
      query: {
        ...wireQuery,
        if (wireBody.containsKey('keyword')) 'keyword': wireBody['keyword'],
      },
    );
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/reports/receipt/detail') {
      return _reportRows([
        {'partyName': 'RECEIPT-001', '__srcId': 'receipt-1'},
      ], total: 1);
    }
    if (path == '/finance/receipts/receipt-1') {
      return {
        'id': 'receipt-1',
        'billNo': 'SK-20261021-001',
        'billDate': '2026-10-21',
        'status': 1,
        'receiptKind': 'RECEIVABLE',
        'items': <Object>[],
      };
    }
    if (path == '/finance/reports/ar-ap/party-locations') {
      final q = Map<String, dynamic>.from(query ?? const {});
      locationQueries.add(q);
      final keyword = q['keyword']?.toString();
      if (largeLocator) {
        final page = (q['page'] as num?)?.toInt() ?? 1;
        locationReads.add((locatorRevision, page));
        locationActivity.add(PagedReadIntent.currentTransportActivity);
        if (locatorRevision == 0 && page == 2 && locationGate != null) {
          return locationGate!.future;
        }
        return {
          'items': [
            {
              'partyType': page == 3 ? 'SUPPLIER' : 'CLIENT',
              'categoryId': page == 1
                  ? 'southeast-asia'
                  : page == 2
                  ? null
                  : 'domestic-supplier',
            },
          ],
          'page': page,
          'size': 100,
          'total': 3,
          'totalPages': 3,
        };
      }
      if (keyword == 'LOCATOR-FAIL') {
        throw StateError('locator unavailable');
      }
      final page = (q['page'] as num?)?.toInt() ?? 1;
      if (keyword == delayLocationKeyword) {
        await (heldLocationDelay ??= Completer<void>()).future;
      }
      if (keyword == 'C-002' ||
          keyword == 'C-003' ||
          keyword == delayLocationKeyword) {
        final item = page == 1
            ? <String, dynamic>{
                'partyType': 'CLIENT',
                'categoryId': 'southeast-asia',
              }
            : <String, dynamic>{
                'partyType': 'SUPPLIER',
                'categoryId': 'domestic-supplier',
              };
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[item],
          'page': page,
          'size': 100,
          'total': 2,
          'totalPages': 2,
        };
      }
      return <String, dynamic>{
        'items': const <Map<String, dynamic>>[],
        'page': page,
        'size': 100,
        'total': 0,
        'totalPages': 0,
      };
    }
    if (path == '/finance/reports/ar-ap/overview') {
      final q = Map<String, dynamic>.from(query ?? const {});
      reportActivityAtDispatch.add(
        PagedReadIntent.currentActivity?.call() ?? true,
      );
      reportQueries.add(q);
      if (_holdNextReport) {
        _holdNextReport = false;
        final held = Completer<Map<String, dynamic>>();
        heldReport = held;
        _heldQuery = q;
        return held.future;
      }
      final keyword = q['keyword']?.toString();
      if (largeSummaryTotal > 0 &&
          q['layout'] == 'RECEIVABLE_SUMMARY' &&
          keyword == null) {
        final page = (q['page'] as num?)?.toInt() ?? 1;
        final size = (q['size'] as num?)?.toInt() ?? 50;
        final offset = (page - 1) * size;
        if (offset == 50 && largeSummaryGate != null) {
          await largeSummaryGate!.future;
        }
        return _forLayout(q, {
          'rows': [
            for (
              var index = offset;
              index < offset + size && index < largeSummaryTotal;
              index++
            )
              {
                'id': 'summary-client-$index',
                'partyCode': 'C-$index',
                'partyName': 'summary-row-$index',
                'balance': '$index.01',
              },
          ],
          'page': page,
          'size': size,
          'total': largeSummaryTotal,
          'totalPages': (largeSummaryTotal + size - 1) ~/ size,
          'readScopeVersion': 'summary-stress-v1',
          'statisticsGeneratedAt': '2026-11-10T00:00:00Z',
        });
      }
      if (delayFirstSearch && keyword == 'C-002') {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (keyword == 'NO-SUCH-PARTY') {
        return _forLayout(q, _reportRows(const []));
      }
      if (keyword == 'C-002' && !delayFirstSearch) {
        // One fixed four-row source in the server's exact-before-near order;
        // every batch is the exact page of the requested size.
        const source = <Map<String, dynamic>>[
          {
            'id': 'client-exact',
            'partyName': 'EXACT-C-002',
            'categoryId': 'southeast-asia',
            'arAmount': 100,
          },
          {
            'id': 'supplier-prefix',
            'partyName': 'PREFIX-C-002',
            'categoryId': 'domestic-supplier',
            'arAmount': 25,
          },
          {
            'id': 'client-near',
            'partyName': 'NEAR-C-002',
            'categoryId': 'overseas',
            'arAmount': 75,
          },
          {
            'id': 'supplier-page2',
            'partyName': 'PAGE2-C-002',
            'categoryId': 'domestic-supplier',
            'arAmount': 50,
          },
        ];
        final page = (q['page'] as num?)?.toInt() ?? 1;
        final size = (q['size'] as num?)?.toInt() ?? 50;
        return {
          ..._reportRows(
            [
              for (
                var i = (page - 1) * size;
                i < page * size && i < source.length;
                i++
              )
                source[i],
            ],
            page: page,
            total: source.length,
            totalPages: (source.length + size - 1) ~/ size,
          ),
          'size': size,
        };
      }
      final label = keyword == null
          ? 'initial'
          : keyword == 'C-002'
          ? 'stale-C-002'
          : 'latest-$keyword';
      return _forLayout(q, _report(label));
    }
    if (path == '/user/preferences') {
      return const <String, dynamic>{'preferences': <String, dynamic>{}};
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

const _summaryKeys = [
  'partyCode',
  'partyName',
  'partyFull',
  'sellerName',
  'director',
  'region',
  'district',
  'creditFloor',
  'prevBalance',
  'shippedAmount',
  'receivedAmount',
  'returnAmount',
  'offsetAmount',
  'balance',
  'overFloor',
  'materialAmount',
];
const _summaryLabels = [
  '客户编号',
  '客户简称',
  '客户全称',
  '业务员',
  '总监',
  '区域',
  '所属地区',
  '铺底额',
  '上月余额',
  '发货金额',
  '回款金额',
  '退货金额',
  '货款冲销',
  '应收余额',
  '超出铺底额',
  '物料金额',
];

Map<String, dynamic> _forLayout(
  Map<String, dynamic> query,
  Map<String, dynamic> response,
) {
  if (query['layout'] != 'RECEIVABLE_SUMMARY') return response;
  return {
    ...response,
    'columns': [
      for (var index = 0; index < _summaryKeys.length; index++)
        {
          'key': _summaryKeys[index],
          'label': _summaryLabels[index],
          'type': index < 7 ? 'text' : 'money',
          'width': index == 2 ? 230 : 120,
          if (index >= 7) 'unitLabel': '元',
        },
    ],
    'rows': [
      for (final row in response['rows'] as List)
        {
          'partyCode': 'C-001',
          'partyFull': '示例客户全称',
          'sellerName': '张龙',
          'director': '黄连芳',
          'region': '内销南区',
          'district': '四川省',
          'creditFloor': 9000,
          'prevBalance': 8000,
          'shippedAmount': 1000,
          'receivedAmount': 200,
          'returnAmount': -100,
          'offsetAmount': 0,
          'balance': 8700,
          'overFloor': -300,
          'materialAmount': null,
          ...Map<String, dynamic>.from(row as Map),
        },
    ],
  };
}

Map<String, dynamic> _report(String partyName) => <String, dynamic>{
  'columns': <Map<String, dynamic>>[
    <String, dynamic>{
      'key': 'partyName',
      'label': '往来单位',
      'type': 'text',
      'width': 220,
    },
  ],
  'rows': <Map<String, dynamic>>[
    <String, dynamic>{'partyName': partyName},
  ],
  'page': 1,
  'size': 50,
  'total': 1,
  'totalPages': 1,
};

Map<String, dynamic> _reportRows(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int total = 0,
  int totalPages = 1,
}) => {
  'columns': [
    {'key': 'partyName', 'label': '往来单位', 'type': 'text', 'width': 220},
    {'key': 'arAmount', 'label': '应收金额', 'type': 'money', 'width': 160},
  ],
  'rows': rows,
  'page': page,
  'size': 50,
  'total': total,
  'totalPages': totalPages,
  'totals': [
    {
      'key': 'arAmount',
      'label': '应收合计',
      'type': 'money',
      'groupKey': 'currency',
      'groups': [
        {'unit': '人民币', 'value': 250},
      ],
    },
  ],
};

class _ClientCategoryRepo implements ClientCategoryRepository {
  @override
  Future<CategoryPrefixAvailability> prefixAvailability(
    String prefix, {
    String? categoryId,
  }) => throw UnsupportedError('not used');

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'overseas',
      code: 'OVERSEAS',
      name: '海外客户',
      level: 0,
      children: [
        ProductCategoryNode(
          id: 'southeast-asia',
          code: 'SEA-001',
          name: '东南亚客户',
          level: 1,
          parentId: 'overseas',
          children: const [],
        ),
      ],
    ),
  ];

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');
  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}

class _SupplierCategoryRepo implements SupplierCategoryRepository {
  @override
  Future<CategoryPrefixAvailability> prefixAvailability(
    String prefix, {
    String? categoryId,
  }) => throw UnsupportedError('not used');

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'domestic-supplier',
      code: 'SUP-DOM',
      name: '国内供应商',
      level: 0,
      children: const [],
    ),
  ];

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');
  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');
  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}
