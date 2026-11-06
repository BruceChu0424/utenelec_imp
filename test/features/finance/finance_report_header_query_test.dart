import '../../support/pump_until.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/data_display/uten_totals_summary_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/features/finance/widgets/finance_date_range_filter.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/supplier_node.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  if (Platform.environment['UTEN_CAPTURE_FINANCE_HEADER'] == 'true') {
    testWidgets('client statement candidate visual', (tester) async {
      final capture = GlobalKey();
      await _pump(tester, 'recon', capture: capture);
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(4);
      await tester.pumpAndSettle();
      // Full business-detail candidates are separate from the original paper,
      // whose party and currency remain mandatory and cannot be guessed.
      await tester.tap(
        find.byKey(const Key('finance-client-statement-view-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('客户名称'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '优腾',
      );
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        capture,
        'finance-client-statement-candidates',
      );
      await tester.tap(find.text('优腾远端客户 (12)'));
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        capture,
        'finance-client-statement-candidate-selected',
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'plastic context1001 keeps the Chinese tail and reuses selected dates during header work',
    (tester) async {
      final api = _HeaderApi()..plasticCount = 1001;
      await _pump(tester, 'cost', separatePrefs: true, suppliedApi: api);
      UtenDropdownField field() => tester.widget<UtenDropdownField>(
        find.byKey(const Key('finance-report-bin')),
      );
      expect(field().items, hasLength(1001));
      expect(field().items.last.value, 'bin-1000');
      expect(field().items.last.label, 'B1000 优腾中文料仓1000末尾');
      expect(api.plasticRequests.map((query) => query['page']), [1, 2]);
      expect(
        api.plasticRequests.every((query) => query['size'] == 1000),
        isTrue,
      );
      final first = api.plasticRequests.first;
      expect(first['dateFrom'], isNotNull);
      expect(first['dateTo'], isNotNull);
      expect(api.plasticRequests.last['readSnapshotRevision'], 'a' * 64);
      await tester.tap(find.byKey(const Key('finance-report-bin')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-dropdown-search-input')),
        '中文料仓1000末尾',
      );
      await tester.pumpAndSettle();
      expect(find.text('B1000 优腾中文料仓1000末尾'), findsOneWidget);
      await tester.tap(find.text('B1000 优腾中文料仓1000末尾'));
      await tester.pumpAndSettle();
      expect(field().value, 'bin-1000');
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSearchSubmitted!('正常中文条件');
      await tester.pumpAndSettle();
      await _scrollWithoutReads(tester, api);
      expect(api.plasticRequests, hasLength(2));
      final export = await _visibleExport(tester);
      expect(export.queryParams, containsPair('binWarehouseId', 'bin-1000'));
      expect(export.queryParams, containsPair('dateFrom', first['dateFrom']));
      expect(export.queryParams, containsPair('dateTo', first['dateTo']));
      // A real explicit refresh must read fresh facts, not a permanent cache.
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      final refresh = Future<void>.sync(table.onRetry!);
      await tester.pumpAndSettle();
      await refresh;
      await tester.pumpAndSettle();
      expect(api.plasticRequests.map((query) => query['page']), [1, 2, 1, 2]);
      final owner = tester.state<NestedScrollViewState>(
        find.descendant(
          of: find.byType(FinanceReportTablePage),
          matching: find.byType(NestedScrollView),
        ),
      );
      owner.innerController.jumpTo(0);
      owner.outerController.jumpTo(0);
      await tester.pumpAndSettle();
      expect(field().items, hasLength(1001));
      expect(api.plasticRequests.map((query) => query['page']), [1, 2, 1, 2]);
      expect(find.byKey(const Key('finance-report-context-retry')), findsNothing);
      expect(api.postRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'plastic same-scope in-flight refreshes share one complete read then explicit refresh is fresh',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final api = _HeaderApi()
        ..plasticCount = 1001
        ..plasticTail = gate;
      await _pump(
        tester,
        'cost',
        separatePrefs: true,
        suppliedApi: api,
        settle: false,
      );
      expect(api.plasticRequests.map((query) => query['page']), [1, 2]);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      final repeats = [
        for (var i = 0; i < 3; i++) Future<void>.sync(table.onRetry!),
      ];
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(api.plasticRequests.map((query) => query['page']), [1, 2]);
      gate.complete(api.plasticPage(api.plasticRequests.last));
      await tester.pumpAndSettle();
      await Future.wait(repeats);
      await tester.pumpAndSettle();
      final field = tester.widget<UtenDropdownField>(
        find.byKey(const Key('finance-report-bin')),
      );
      expect(field.items, hasLength(1001));
      expect(field.items.last.value, 'bin-1000');
      final refresh = Future<void>.sync(
        tester
            .widget<MasterDataTableView<Map<String, dynamic>>>(
              find.byType(MasterDataTableView<Map<String, dynamic>>),
            )
            .onRetry!,
      );
      await tester.pumpAndSettle();
      await refresh;
      await tester.pumpAndSettle();
      expect(api.plasticRequests.map((query) => query['page']), [1, 2, 1, 2]);
      expect(api.postRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'plastic empty accepted scope avoids ordinary repeat reads but explicit refresh reads again',
    (tester) async {
      final api = _HeaderApi()..plasticCount = 0;
      await _pump(tester, 'cost', separatePrefs: true, suppliedApi: api);
      final toolbar = tester.widget<UtenFilterToolbar<int>>(
        find.byType(UtenFilterToolbar<int>),
      );
      for (final keyword in ['中文一', '中文二', '']) {
        toolbar.onSearchSubmitted!(keyword);
        await tester.pumpAndSettle();
      }
      expect(api.plasticRequests.map((query) => query['page']), [1]);
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('finance-report-bin')),
            )
            .items,
        isEmpty,
      );
      final refresh = Future<void>.sync(
        tester
            .widget<MasterDataTableView<Map<String, dynamic>>>(
              find.byType(MasterDataTableView<Map<String, dynamic>>),
            )
            .onRetry!,
      );
      await tester.pumpAndSettle();
      await refresh;
      await tester.pumpAndSettle();
      expect(api.plasticRequests.map((query) => query['page']), [1, 1]);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(api.postRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'plastic date owner changes retire a held old tail without publishing its prefix',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final api = _HeaderApi()
        ..plasticCount = 1001
        ..plasticTail = gate
        ..plasticLabelsByDate = true;
      await _pump(
        tester,
        'cost',
        separatePrefs: true,
        suppliedApi: api,
        settle: false,
      );
      expect(api.plasticRequests, hasLength(2));
      final oldTail = Map<String, dynamic>.of(api.plasticRequests.last);
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('finance-report-bin')),
            )
            .items,
        isEmpty,
      );
      final date = tester.widget<FinanceDateRangeFilter>(
        find.byType(FinanceDateRangeFilter),
      );
      final change = Future<void>.sync(
        () => date.onChanged(DateTime(2025, 2), DateTime(2025, 2, 28)),
      );
      await tester.pumpAndSettle();
      await change;
      expect(api.plasticRequests, hasLength(4));
      expect(
        api.plasticRequests
            .skip(2)
            .every(
              (query) =>
                  query['dateFrom'] == '2025-02-01' &&
                  query['dateTo'] == '2025-02-28',
            ),
        isTrue,
      );
      UtenDropdownField field() => tester.widget<UtenDropdownField>(
        find.byKey(const Key('finance-report-bin')),
      );
      await _awaitCompletePlasticContext(tester);
      expect(field().items, hasLength(1001));
      expect(
        field().items.every((item) => item.value!.startsWith('new-bin-')),
        isTrue,
      );
      gate.complete(api.plasticPage(oldTail));
      await tester.pumpAndSettle();
      expect(field().items, hasLength(1001));
      expect(
        field().items.every((item) => item.label.contains('新日期中文料仓')),
        isTrue,
      );
      expect(
        field().items.any((item) => item.label.contains('旧日期中文料仓')),
        isFalse,
      );
      expect(api.plasticRequests, hasLength(4));
      expect(api.postRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'successful-write revision retires the same-date held plastic owner before a fresh retry',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final api = _HeaderApi()
        ..plasticCount = 1001
        ..plasticTail = gate
        ..plasticLabelsByVersion = true;
      await _pump(
        tester,
        'cost',
        separatePrefs: true,
        suppliedApi: api,
        settle: false,
      );
      expect(api.plasticRequests, hasLength(2));
      final oldTail = Map<String, dynamic>.of(api.plasticRequests.last);
      final oldResponse = api.plasticPage(oldTail);
      final environment = ProviderScope.containerOf(
        tester.element(find.byType(FinanceReportTablePage)),
      );
      // Existing middleware's monotonic successful-write notification; no new
      // UI-owned epoch and no replay of a business command is introduced.
      api.plasticDataRound = 1;
      environment.read(dataWriteRevisionProvider.notifier).state++;
      final pending = Future<void>.sync(
        tester
            .widget<MasterDataTableView<Map<String, dynamic>>>(
              find.byType(MasterDataTableView<Map<String, dynamic>>),
            )
            .onRetry!,
      );
      await tester.pumpAndSettle();
      await pending;
      expect(api.plasticRequests, hasLength(4));
      expect(
        api.plasticRequests.every(
          (query) =>
              query['dateFrom'] == oldTail['dateFrom'] &&
              query['dateTo'] == oldTail['dateTo'],
        ),
        isTrue,
      );
      UtenDropdownField field() => tester.widget<UtenDropdownField>(
        find.byKey(const Key('finance-report-bin')),
      );
      await _awaitCompletePlasticContext(tester);
      expect(field().items, hasLength(1001));
      expect(
        field().items.every((item) => item.value!.startsWith('new-write-bin-')),
        isTrue,
      );
      expect(api.plasticRequests.last['readSnapshotRevision'], 'd' * 64);
      gate.complete(oldResponse);
      await tester.pumpAndSettle();
      expect(
        field().items.every((item) => item.label.contains('写后中文料仓')),
        isTrue,
      );
      expect(
        field().items.any((item) => item.label.contains('写前中文料仓')),
        isFalse,
      );
      expect(api.plasticRequests, hasLength(4));
      expect(api.postRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'plastic tail error publishes no prefix and explicit retry reaches the complete tail',
    (tester) async {
      final api = _HeaderApi()
        ..plasticCount = 1001
        ..plasticTailFailures = 1;
      await _pump(tester, 'cost', separatePrefs: true, suppliedApi: api);
      UtenDropdownField field() => tester.widget<UtenDropdownField>(
        find.byKey(const Key('finance-report-bin')),
      );
      expect(field().items, isEmpty);
      expect(api.plasticRequests.map((query) => query['page']), [1, 2]);
      expect(
        find.byKey(const Key('finance-report-context-retry')),
        findsOneWidget,
      );
      expect(find.byType(UtenBusyOverlay), findsNothing);
      await tester.tap(find.byKey(const Key('finance-report-context-retry')));
      await tester.pumpAndSettle();
      expect(field().items, hasLength(1001));
      expect(field().items.last.value, 'bin-1000');
      expect(api.plasticRequests.map((query) => query['page']), [1, 2, 1, 2]);
      expect(
        find.byKey(const Key('finance-report-context-retry')),
        findsNothing,
      );
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(api.postRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clicking an initial full-report text suggestion also commits Search',
    (tester) async {
      final api = await _pump(tester, 'recon');
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(4);
      await tester.pumpAndSettle();
      // Full business-detail candidates are separate from the original paper,
      // whose party and currency remain mandatory and cannot be guessed.
      await tester.tap(
        find.byKey(const Key('finance-client-statement-view-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('客户名称'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('优腾远端客户 (12)'));
      await tester.pumpAndSettle();
      expect(
        api.requests.last.$2,
        containsPair('f.search.clientName', '优腾远端客户'),
      );
      expect(api.requests.last.$2.containsKey('f.clientName'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'client statement candidates read the full report and click applies a keyword',
    (tester) async {
      final api = await _pump(tester, 'recon');
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(4);
      await tester.pumpAndSettle();
      // Full business-detail candidates are separate from the original paper,
      // whose party and currency remain mandatory and cannot be guessed.
      await tester.tap(
        find.byKey(const Key('finance-client-statement-view-toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('客户名称'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '优腾',
      );
      await tester.pump(const Duration(milliseconds: 251));
      await tester.pumpAndSettle();
      expect(
        api.candidateRequests.last,
        containsPair('report', 'statements/client'),
      );
      expect(api.candidateRequests.last, containsPair('column', 'clientName'));
      expect(api.candidateRequests.last, containsPair('__facetKeyword', '优腾'));
      expect(find.text('优腾远端客户 (12)'), findsOneWidget);
      await tester.tap(find.text('优腾远端客户 (12)'));
      await tester.pumpAndSettle();
      expect(
        api.requests.last.$2,
        containsPair('f.search.clientName', '优腾远端客户'),
      );
      expect(api.requests.last.$2.containsKey('f.clientName'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'complete client statement shares customer names with local scroll, print and export',
    (tester) async {
      final capture = GlobalKey();
      final api = await _pump(tester, 'recon', capture: capture);
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(4);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('finance-client-statement-view-toggle')),
      );
      await tester.pumpAndSettle();
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().columns.take(3).map((column) => column.key), [
        'billDate',
        'clientName',
        'goodsName',
      ]);
      expect(find.text('客户名称'), findsOneWidget);
      expect(find.text('甲客户'), findsWidgets);
      table().onFilterChanged('search.clientName', '甲客户');
      await tester.pumpAndSettle();
      table().onSortChange!('clientName', false);
      await tester.pumpAndSettle();
      await _scrollWithoutReads(tester, api);
      expect(api.requests.last.$2, containsPair('f.search.clientName', '甲客户'));
      expect(api.requests.last.$2, containsPair('sort', 'clientName'));
      final export = table().toolbarActions!
          .whereType<UtenExportButton>()
          .single;
      expect(export.report, 'statements/client');
      expect(export.queryParams, containsPair('f.search.clientName', '甲客户'));
      final printed = await tester.runAsync(
        () => table().toolbarActions!
            .whereType<UtenPrintPreviewButton>()
            .single
            .loader(),
      );
      expect(printed!.headers, contains('客户名称'));
      expect(printed.rows.first[1], '甲客户');
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final rendered = await boundary.toImage();
        final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/staff-feedback/client-statement.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
        rendered.dispose();
      });
      api.delayedClient = Completer<Map<String, dynamic>>();
      table().onFilterChanged('search.clientName', '旧条件');
      await tester.pump(const Duration(milliseconds: 600));
      table().onFilterChanged('search.clientName', '新条件');
      await tester.pumpAndSettle();
      expect(table().items, hasLength(2));
      expect(table().items.every((row) => row['clientName'] == '新条件'), isTrue);
      expect(api.requests.last.$2['layout'], isNull);
      api.delayedClient!.complete(
        _clientStatementData({'f.search.clientName': '旧条件'}),
      );
      await tester.pumpAndSettle();
      expect(table().items, hasLength(2));
      expect(table().items.every((row) => row['clientName'] == '新条件'), isTrue);
      api.delayedClient = Completer<Map<String, dynamic>>();
      table().onFilterChanged('search.clientName', '跨视图旧条件');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(
        find.byKey(const Key('finance-client-statement-view-toggle')),
      );
      await tester.pumpAndSettle();
      api.delayedClient!.complete(
        _clientStatementData({'f.search.clientName': '跨视图旧条件'}),
      );
      await tester.pumpAndSettle();
      // Main keeps trusted empty headers and the date toolbar available;
      // missing original-paper identities must still publish no old facts.
      final emptyTable = tester
          .widget<MasterDataTableView<Map<String, dynamic>>>(
            find.byType(MasterDataTableView<Map<String, dynamic>>),
          );
      expect(emptyTable.items, isEmpty);
      expect(emptyTable.totalPages, 0);
      expect(find.text('请选择实际往来对象和币别，按原表查看对账单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('对账成本和总账各自恢复分类，不受钱流明细分类影响', (tester) async {
    for (final entry in [
      ('detail', '/ar-ap/detail'),
      ('recon', '/statements/supplier'),
      ('cost', '/cost/plastic'),
      ('gl', '/gl/profit-monthly'),
    ]) {
      final api = await _pump(tester, entry.$1, separatePrefs: true);
      expect(api.requests.first.$1, endsWith(entry.$2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
  testWidgets(
    'report headers keep the complete query across local scroll export and currency clear without replay',
    (tester) async {
      final api = await _pump(tester, 'detail');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      final keys = Set.of(table().serverColumnSearchKeys);
      var money = table().columns.singleWhere(
        (column) => column.key == 'expectedOriginal',
      );
      expect(money.columnSearchEnabled, isFalse);
      expect(money.sortable, isFalse);
      table().onFilterChanged('currencyCode', 'currency-id');
      await tester.pumpAndSettle();
      money = table().columns.singleWhere(
        (column) => column.key == 'expectedOriginal',
      );
      expect(money.columnSearchEnabled, isTrue);
      expect(money.exactValueOf!(table().items.first), '90071992547409.1234');
      table().onFilterChanged(
        'search.expectedOriginal',
        '>=90071992547409.1234',
      );
      await tester.pumpAndSettle();
      table().onFilterChanged('search.orderDate', '2026-10..2026-11');
      await tester.pumpAndSettle();
      table().onSortChange!('expectedOriginal', false);
      await tester.pumpAndSettle();
      await _scrollWithoutReads(tester, api);
      expect(
        api.requests.last.$2,
        containsPair('f.search.expectedOriginal', '>=90071992547409.1234'),
      );
      expect(find.textContaining('search.expectedOriginal:'), findsNothing);
      expect(
        table().filters,
        containsPair('search.expectedOriginal', '>=90071992547409.1234'),
      );
      expect(
        api.requests.last.$2,
        containsPair('f.search.orderDate', '2026-10..2026-11'),
      );
      final export = await _visibleExport(tester);
      expect(
        export.queryParams,
        containsPair('f.search.expectedOriginal', '>=90071992547409.1234'),
      );
      expect(export.queryParams, containsPair('f.currencyCode', 'currency-id'));
      table().onFilterChanged('currencyCode', null);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(api.requests.last.$2['f.search.expectedOriginal'], isNull);
      expect(api.requests.last.$2['sort'], isNull);
      expect(api.requests.last.$2['f.search.orderDate'], '2026-10..2026-11');
      expect(table().serverColumnSearchKeys, keys);
      expect(
        table().columns
            .singleWhere((column) => column.key == 'expectedOriginal')
            .columnSearchEnabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'C2 inventory context is explicit and balance timeline cannot be reordered',
    (tester) async {
      await _pump(tester, 'recon');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().headerFilterScopeDescription, contains('整组事实'));
      expect(table().headerFilterScopeDescription, contains('重复显示'));
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(3);
      await tester.pumpAndSettle();
      await _selectMaterialContext(tester);
      expect(
        table().columns
            .where((column) => column.type == 'number')
            .every((column) => !column.sortable),
        isTrue,
      );
      expect(table().serverColumnSearchKeys, contains('balance'));
      expect(
        table().columns
            .singleWhere((column) => column.key == 'balance')
            .columnSearchEnabled,
        isTrue,
      );
    },
  );
  testWidgets(
    'rejected new report conditions keep trusted headers without old facts or counts',
    (tester) async {
      final api = await _pump(tester, 'detail');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().items, isNotEmpty);
      api.rejectHeaders = true;
      table().onFilterChanged('search.orderNo', 'REJECTED-NEW-SCOPE');
      await tester.pumpAndSettle();
      expect(table().items, isEmpty);
      expect(table().facets, isEmpty);
      expect(table().summaryBar, isNull);
      expect(table().filters['search.orderNo'], 'REJECTED-NEW-SCOPE');
      expect(table().error, '暂时无法检索');
      expect(table().serverColumnSearchKeys, contains('orderNo'));
      // A second unsuccessful correction still has the same authorized schema;
      // unknown result counts and old rows never become an accepted query.
      table().onFilterChanged('search.orderNo', 'REJECTED-NEXT-SCOPE');
      await tester.pumpAndSettle();
      expect(table().items, isEmpty);
      expect(table().facets, isEmpty);
      expect(table().summaryBar, isNull);
      expect(table().serverColumnSearchKeys, contains('orderNo'));
      expect(table().totalPages, -1);
      api.rejectHeaders = false;
      table().onFilterChanged('search.orderNo', null);
      await tester.pumpAndSettle();
      expect(table().items, isNotEmpty);
      expect(table().error, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  for (final denial in [
    (401, 'UNAUTHORIZED'),
    (403, 'FORBIDDEN'),
    (409, 'READ_SCOPE_CHANGED'),
  ]) {
    testWidgets(
      'confirmed report denial clears prior schema and facts: ${denial.$2}',
      (tester) async {
        final api = await _pump(tester, 'detail');
        MasterDataTableView<Map<String, dynamic>> table() => tester.widget(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        expect(table().items, hasLength(2));
        expect(table().serverColumnSearchKeys, contains('orderNo'));
        api.rejectHeaders = true;
        api.rejectionStatus = denial.$1;
        api.rejectionCode = denial.$2;
        table().onFilterChanged('search.orderNo', 'REVOKED-SOURCE');
        await tester.pumpAndSettle();
        expect(table().items, isEmpty);
        expect(table().facets, isEmpty);
        expect(table().columns, isEmpty);
        expect(table().serverColumnSearchKeys, isEmpty);
        expect(table().summaryBar, isNull);
        expect(table().filters['search.orderNo'], 'REVOKED-SOURCE');
        expect(table().error, '暂时无法检索');
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'failed currency-scope change never borrows the former money schema',
    (tester) async {
      final api = await _pump(tester, 'detail');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      table().onFilterChanged('currencyCode', 'first-currency');
      await tester.pumpAndSettle();
      expect(table().serverColumnSearchKeys, contains('expectedOriginal'));
      table().onFilterChanged('search.orderNo', 'SAME-AUTHORIZED-SCHEMA');
      await tester.pumpAndSettle();
      expect(table().serverColumnSearchKeys, contains('orderNo'));
      expect(table().items, hasLength(2));
      api.rejectHeaders = true;
      table().onFilterChanged('currencyCode', 'different-currency');
      await tester.pumpAndSettle();
      expect(table().items, isEmpty);
      expect(table().facets, isEmpty);
      expect(table().columns, isEmpty);
      expect(table().serverColumnSearchKeys, isEmpty);
      expect(table().summaryBar, isNull);
      expect(table().filters['currencyCode'], 'different-currency');
      expect(table().filters['search.orderNo'], 'SAME-AUTHORIZED-SCHEMA');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'all original GL layouts preserve source row order including trial balance',
    (tester) async {
      final api = await _pump(tester, 'gl');
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().columns.every((column) => !column.sortable), isTrue);
      for (final index in const [1, 2, 3, 4, 5, 6, 7]) {
        tester
            .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
            .onSelectionChanged!(index);
        await tester.pumpAndSettle();
        expect(
          table().columns
              .where(
                (column) =>
                    const {'number', 'money', 'date'}.contains(column.type),
              )
              .every((column) => !column.sortable),
          isTrue,
        );
        table().onSortChange!('orderDate', false);
        final key = table().columns
            .firstWhere((column) => column.type == 'text')
            .key;
        table().onFilterChanged('search.$key', 'MATCH');
        await tester.pumpAndSettle();
        expect(api.requests.last.$2['sort'], isNull);
        expect((await _visibleExport(tester)).queryParams['sort'], isNull);
      }
    },
  );
  testWidgets(
    'balance template retains both original sides and eight columns in report and export',
    (tester) async {
      final api = await _pump(tester, 'gl');
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(1);
      await tester.pumpAndSettle();
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().columns.map((c) => c.label), [
        '资产',
        '行次',
        '期末余额',
        '年初余额',
        '负债和所有者权益',
        '行次',
        '期末余额',
        '年初余额',
      ]);
      expect(table().items.single['assetLineNo'], 1);
      expect(table().items.single['liabilityLineNo'], 31);
      final item = table().items.single;
      final context = tester.element(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(
        table().columns.firstWhere((c) => c.key == 'assetItem').cellColor!(
          context,
          item,
        ),
        const Color(0xff808080),
      );
      expect(
        table().columns.firstWhere((c) => c.key == 'assetLineNo').cellColor!(
          context,
          item,
        ),
        isNull,
      );
      expect(
        table().columns.firstWhere((c) => c.key == 'liabilityEnd').cellColor!(
          context,
          item,
        ),
        isNull,
      );
      expect(api.requests.last.$2['layout'], 'template');
      expect((await _visibleExport(tester)).queryParams['layout'], 'template');
      expect(table().serverColumnSearchKeys, isNot(contains('side')));
    },
  );
  testWidgets('C2 unproved price placeholders expose neither search nor sort', (
    tester,
  ) async {
    final api = await _pump(tester, 'recon');
    MasterDataTableView<Map<String, dynamic>> table() =>
        tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
    for (final key in ['materialPrice', 'materialAmount']) {
      final column = table().columns.singleWhere((column) => column.key == key);
      expect(column.columnSearchEnabled, isFalse);
      expect(column.sortable, isFalse);
      expect(table().serverColumnSearchKeys, isNot(contains(key)));
    }
    table().onFilterChanged('currencyCode', 'currency-id');
    await tester.pumpAndSettle();
    expect(
      table().columns
          .singleWhere((column) => column.key == 'processAmount')
          .columnSearchEnabled,
      isTrue,
    );
    table().onSortChange!('materialPrice', false);
    table().onFilterChanged('search.goodsName', 'KNOWN');
    await tester.pumpAndSettle();
    expect(api.requests.last.$2['sort'], isNull);
  });
  testWidgets(
    'detail footer keeps authoritative full-scope totals across the complete result and local scroll',
    (tester) async {
      final api = await _pump(tester, 'detail', serverTotals: true);
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(1);
      await tester.pumpAndSettle();
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(table().items.map((row) => row['debit']), [10, 1224.56]);
      UtenTotalsSummaryBar totals() =>
          tester.widget(find.byType(UtenTotalsSummaryBar));
      final amount = totals().entries.singleWhere(
        (entry) => entry.label == '所列记录本期借方合计',
      );
      expect(amount.value.replaceAll(RegExp(r'[^0-9.\-]'), ''), '1234.56');
      expect(amount.value, contains('元'));
      await _scrollWithoutReads(tester, api);
      expect(
        totals().entries
            .singleWhere((entry) => entry.label == '所列记录本期借方合计')
            .value,
        amount.value,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'trial original totals remain inline without a duplicate footer',
    (tester) async {
      await _pump(tester, 'gl');
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(table.columns.map((c) => c.label), [
        '科目编码',
        '科目名称',
        '外币名称',
        '期初借方',
        '期初贷方',
        '本期发生借方',
        '本期发生贷方',
        '期末借方',
        '期末贷方',
      ]);
      expect(table.items.last['__rowKind'], 'TOTAL');
      expect(table.items.last['name'], '总合计');
      expect(find.byType(UtenTotalsSummaryBar), findsNothing);
    },
  );
  testWidgets(
    'statement waits for both identities and clearing either removes prior facts',
    (tester) async {
      final api = await _pump(tester, 'recon', selectContext: false);
      expect(api.requests, isEmpty);
      await _selectStatementContext(tester, selectCurrency: false);
      expect(api.requests, isEmpty);
      tester
          .widget<UtenDropdownField>(
            find.byKey(const Key('finance-report-currency')),
          )
          .onChanged
          .call('currency-id');
      await tester.pumpAndSettle();
      expect(api.requests.last.$2, containsPair('partyId', 'supplier-id'));
      expect(api.requests.last.$2, containsPair('currencyId', 'currency-id'));
      final count = api.requests.length;
      tester
          .widget<UtenDropdownField>(
            find.byKey(const Key('finance-report-currency')),
          )
          .onChanged
          .call(null);
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(count));
      // Main keeps trusted empty headers and the date toolbar available;
      // missing original-paper identities must still publish no old facts.
      final emptyTable = tester
          .widget<MasterDataTableView<Map<String, dynamic>>>(
            find.byType(MasterDataTableView<Map<String, dynamic>>),
          );
      expect(emptyTable.items, isEmpty);
      expect(emptyTable.totalPages, 0);
      expect(find.text('请选择实际往来对象和币别，按原表查看对账单'), findsOneWidget);
    },
  );
  testWidgets(
    'material statement uses the selected group and actual paper currency rather than its book property',
    (tester) async {
      final api = await _pump(tester, 'recon');
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(3);
      await tester.pumpAndSettle();
      expect(
        api.requests.where((r) => r.$1.endsWith('/other-receivable')),
        isEmpty,
      );
      await _selectMaterialContext(tester);
      final query = api.requests.last.$2;
      expect(query, containsPair('materialContextId', 'material-id'));
      expect(query, containsPair('partyId', 'supplier-id'));
      expect(query, containsPair('currencyId', 'actual-usd-id'));
      expect(query['currencyId'], isNot('book-cny-id'));
      expect(
        (await _visibleExport(tester)).queryParams,
        containsPair('materialContextId', 'material-id'),
      );
    },
  );
  testWidgets(
    'closing a material picker during loading cannot later select or publish its old group',
    (tester) async {
      final api = await _pump(tester, 'recon');
      tester
          .widget<UtenFilterToolbar<int>>(find.byType(UtenFilterToolbar<int>))
          .onSelectionChanged!(3);
      await tester.pumpAndSettle();
      final pending = Completer<Map<String, dynamic>>();
      api.materialContexts = pending;
      await tester.tap(
        find.byKey(const Key('finance-material-context-select')),
      );
      await tester.pump();
      Navigator.of(tester.element(find.text('选择对账资料').last)).pop();
      await tester.pumpAndSettle();
      pending.complete({
        'items': [_materialContext],
        'totalPages': 1,
      });
      await tester.pumpAndSettle();
      expect(
        api.requests.where((r) => r.$1.endsWith('/other-receivable')),
        isEmpty,
      );
      expect(find.text('请选择已审核的对账资料，按原表查看'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

const _materialContext = <String, dynamic>{
  'id': 'material-id',
  'state': 'APPROVED',
  'auxiliaryCode': 'J001',
  'auxiliaryName': '匿名加工往来',
  'goodsName': '匿名产品',
  'productNameCaption': '原产品名称',
  'accountCode': '1221',
  'accountingCurrencyId': 'book-cny-id',
  'accountingCurrencyCode': 'CNY',
  'actualCurrencyId': 'actual-usd-id',
  'partyId': 'supplier-id',
  'partyRole': 'SUPPLIER',
  'amountBasis': 'ORIGINAL',
};

Future<void> _selectMaterialContext(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('finance-material-context-select')));
  await tester.pumpAndSettle();
  final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
    find.byType(MasterDataTableView<Map<String, dynamic>>).last,
  );
  table.onRowTap!(table.items.single);
  await tester.pumpAndSettle();
}

Future<void> _selectStatementContext(
  WidgetTester tester, {
  bool selectCurrency = true,
}) async {
  final party = find.byKey(const Key('finance-report-party'));
  await tester.ensureVisible(party);
  await tester.tap(party);
  await tester.pumpAndSettle();
  Navigator.of(
    tester.element(find.text('选择供应商').last),
  ).pop(const SupplierListItem(id: 'supplier-id', code: 'S001', name: '匿名供应商'));
  await tester.pumpAndSettle();
  if (selectCurrency) {
    tester
        .widget<UtenDropdownField>(
          find.byKey(const Key('finance-report-currency')),
        )
        .onChanged
        .call('currency-id');
    await tester.pumpAndSettle();
  }
}

Future<void> _scrollWithoutReads(WidgetTester tester, _HeaderApi api) async {
  final table = find.byType(MasterDataTableView<Map<String, dynamic>>);
  final before = api.requests.length;
  for (final state in tester.stateList<ScrollableState>(
    find.descendant(of: table, matching: find.byType(Scrollable)),
  )) {
    if (state.position.axis == Axis.vertical &&
        state.position.hasContentDimensions) {
      state.position.jumpTo(state.position.maxScrollExtent);
    }
  }
  await tester.pumpAndSettle();
  expect(api.requests, hasLength(before));
  expect(find.byKey(const ValueKey('master-table-page-next')), findsNothing);
}

Future<UtenExportButton> _visibleExport(WidgetTester tester) async {
  var opened = false;
  if (find.byType(UtenExportButton).evaluate().isEmpty) {
    final trigger = find
        .descendant(
          of: find.byType(MasterDataTableView<Map<String, dynamic>>),
          matching: find.byKey(const ValueKey('uten-action-overflow-trigger')),
        )
        .first;
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    opened = true;
  }
  final result = tester.widget<UtenExportButton>(find.byType(UtenExportButton));
  if (opened) {
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
  }
  return result;
}

Future<_HeaderApi> _pump(
  WidgetTester tester,
  String card, {
  bool serverTotals = false,
  bool separatePrefs = false,
  bool selectContext = true,
  GlobalKey? capture,
  _HeaderApi? suppliedApi,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(1800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = (suppliedApi ?? _HeaderApi())..serverTotals = serverTotals;
  if (capture != null) await loadAuditScreenshotFonts(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeReportExport,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        if (separatePrefs) ...[
          financeDetailReportPrefsProvider.overrideWith(_DetailPrefs.new),
          financeReconReportPrefsProvider.overrideWith(_ReconPrefs.new),
          financeCostReportPrefsProvider.overrideWith(_CostPrefs.new),
          financeGlReportPrefsProvider.overrideWith(_GlPrefs.new),
        ],
      ],
      child: RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: capture == null
              ? null
              : auditScreenshotTheme(buildLightTheme()),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: FinanceReportTablePage(cardId: card),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var frame = 0; frame < 30 && api.plasticRequests.length < 2; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }
  if (card == 'recon' && selectContext) await _selectStatementContext(tester);
  return api;
}

Map<String, dynamic> _clientStatementData(Map<String, dynamic> query) => {
  'readScopeVersion': 'scope-1',
  'columns': [
    {'key': 'billDate', 'label': '开单日期', 'type': 'date', 'width': 140},
    {'key': 'clientName', 'label': '客户名称', 'type': 'text', 'width': 180},
    {'key': 'goodsName', 'label': '货品名称', 'type': 'text', 'width': 220},
    {'key': 'qty', 'label': '数量', 'type': 'number', 'unitKey': 'unit'},
    {'key': 'unit', 'label': '单位', 'type': 'text'},
    {
      'key': 'price',
      'label': '含税单价',
      'type': 'money',
      'unitKey': 'currencyCode',
    },
    {
      'key': 'amount',
      'label': '含税金额',
      'type': 'money',
      'unitKey': 'currencyCode',
    },
    {'key': 'remark', 'label': '备注', 'type': 'text'},
    {'key': 'currencyCode', 'label': '币别', 'type': 'text'},
  ],
  'columnSearchKeys': ['billDate', 'clientName', 'goodsName', 'qty', 'remark'],
  'rows': [
    {
      'billDate': '2026-11-03',
      'clientName': query['f.search.clientName'] ?? '甲客户',
      'goodsName': '优腾三联双控开关',
      'unit': '个',
      'qty': 100,
      'price': 13.11,
      'amount': 1311,
      'remark': 'XC202611030001',
      'currencyCode': '人民币',
    },
  ],
  'facets': <String, dynamic>{},
  'page': query['page'] ?? 1,
  // This fixture's server deliberately clamps every transport batch to one
  // row; page/count/size describe the same complete two-row source.
  'size': 1,
  'total': 2,
  'totalPages': 2,
};

class _DetailPrefs extends FinanceDetailReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(docType: '1');
}

class _ReconPrefs extends FinanceReconReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(docType: '2');
}

class _CostPrefs extends FinanceCostReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(docType: '4');
}

class _GlPrefs extends FinanceGlReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(docType: '3');
}

class _HeaderApi extends ApiClient {
  Completer<Map<String, dynamic>>? delayedClient;
  _HeaderApi() : super(Dio());
  final requests = <(String, Map<String, dynamic>)>[];
  final candidateRequests = <Map<String, dynamic>>[];
  final plasticRequests = <Map<String, dynamic>>[];
  final postRequests = <String>[];
  int plasticCount = 1, plasticTailFailures = 0, plasticDataRound = 0;
  bool plasticLabelsByDate = false, plasticLabelsByVersion = false;
  String? firstPlasticScope;
  Completer<Map<String, dynamic>>? plasticTail;

  Map<String, dynamic> plasticPage(Map<String, dynamic> query) {
    final page = query['page'] as int, size = query['size'] as int;
    final scope = '${query['dateFrom']}/${query['dateTo']}';
    firstPlasticScope ??= scope;
    final initial = scope == firstPlasticScope, start = (page - 1) * size;
    final prefix = plasticLabelsByVersion
        ? (plasticDataRound == 0 ? '写前中文料仓' : '写后中文料仓')
        : plasticLabelsByDate
        ? (initial ? '旧日期中文料仓' : '新日期中文料仓')
        : '优腾中文料仓';
    final idPrefix = plasticLabelsByVersion
        ? (plasticDataRound == 0 ? 'old-write-bin-' : 'new-write-bin-')
        : plasticLabelsByDate
        ? (initial ? 'old-bin-' : 'new-bin-')
        : 'bin-';
    return {
      'items': [
        for (var i = start; i < start + size && i < plasticCount; i++)
          {
            'id': plasticCount == 1 ? 'bin-id' : '$idPrefix$i',
            'code': plasticCount == 1
                ? 'B001'
                : 'B${i.toString().padLeft(4, '0')}',
            'name': plasticCount == 1
                ? '匿名内料仓'
                : '$prefix$i${i == plasticCount - 1 ? '末尾' : ''}',
          },
      ],
      'page': page,
      'size': size,
      'total': plasticCount,
      'totalPages': (plasticCount + size - 1) ~/ size,
      'scope': 'all',
      'readScopeVersion': 'scope-1',
      'readDataVersion': (plasticDataRound == 0 ? 'c' : 'e') * 64,
      'readSnapshotRevision':
          (plasticDataRound == 0 ? (initial ? 'a' : 'b') : 'd') * 64,
    };
  }

  @override
  Future<Map<String, dynamic>> postForm(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    candidateRequests.add(Map.of(body));
    return {
      'field': 'value',
      'page': body['__facetPage'],
      'size': body['__facetSize'],
      'items': [
        {'value': '优腾远端客户', 'label': '优腾远端客户', 'count': 12},
      ],
      'hasMore': false,
      'readScopeVersion': 'scope-1',
    };
  }

  bool rejectHeaders = false;
  int rejectionStatus = 503;
  String rejectionCode = 'TEMPORARY';
  bool serverTotals = false;
  Completer<Map<String, dynamic>>? materialContexts;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.endsWith('/currencies/dict')
      ? [
          {'id': 'currency-id', 'name': '美金', 'code': 'USD'},
        ]
      : [];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postRequests.add(path);
    return {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 100,
      'total': 0,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/material-statements') {
      return materialContexts?.future ??
          {
            'items': [_materialContext],
            'page': 1,
            'size': 50,
            'total': 1,
            'totalPages': 1,
          };
    }
    if (!path.startsWith('/finance/reports/')) return {};
    if (path == '/finance/reports/context/plastic-bins/summaries') {
      final values = Map<String, dynamic>.of(query ?? {});
      plasticRequests.add(values);
      final response = plasticPage(values);
      expectSync(values['size'], 1000);
      expectSync(values['dateFrom'], isNotNull);
      expectSync(values['dateTo'], isNotNull);
      final page = values['page'] as int;
      expectSync(
        values['readSnapshotRevision'],
        page == 1 ? isNull : response['readSnapshotRevision'],
      );
      if (page == 2 && plasticTailFailures > 0) {
        plasticTailFailures--;
        throw ApiException('TEMPORARY', '料仓尾批读取失败', httpStatus: 503);
      }
      if (page == 2 &&
          plasticTail != null &&
          !plasticTail!.isCompleted &&
          plasticDataRound == 0 &&
          '${values['dateFrom']}/${values['dateTo']}' == firstPlasticScope) {
        return plasticTail!.future;
      }
      return response;
    }
    if (path == '/finance/reports/context/plastic-bins') {
      throw StateError(
        'Live plastic caller must use the complete summary protocol',
      );
    }
    final parameters = Map<String, dynamic>.of(query ?? {});
    requests.add((path, parameters));
    if (path.endsWith('/statements/client')) {
      if (parameters['f.search.clientName']?.toString().contains('旧条件') ==
              true &&
          delayedClient != null) {
        return delayedClient!.future;
      }
      return _clientStatementData(parameters);
    }
    if (rejectHeaders && parameters.containsKey('f.search.orderNo')) {
      throw ApiException(rejectionCode, '暂时无法检索', httpStatus: rejectionStatus);
    }
    if (serverTotals && path.endsWith('/ar-ap/detail')) {
      final page = parameters['page'] ?? 1;
      return {
        'readScopeVersion': 'scope-1',
        'columns': [
          {'key': 'code', 'label': '科目编码', 'type': 'text'},
          {'key': 'name', 'label': '科目', 'type': 'text'},
          {'key': 'debit', 'label': '本期借方', 'type': 'money', 'unitLabel': '元'},
          {'key': 'credit', 'label': '本期贷方', 'type': 'money', 'unitLabel': '元'},
        ],
        'columnSearchKeys': ['code', 'name', 'debit', 'credit'],
        'rows': [
          {
            'code': 'ACCOUNT-$page',
            'name': '科目',
            'debit': page == 1 ? 10 : 1224.56,
            'credit': page == 1 ? 0 : 345.67,
          },
        ],
        'facets': <String, dynamic>{},
        'page': page,
        'size': 1,
        'total': 2,
        'totalPages': 2,
        'totals': [
          {
            'key': 'debit',
            'label': '所列记录本期借方合计',
            'type': 'money',
            'groupKey': null,
            'unitLabel': '元',
            'groups': [
              {'unit': null, 'value': 1234.56, 'valueExact': '1234.5600'},
            ],
          },
          {
            'key': 'credit',
            'label': '所列记录本期贷方合计',
            'type': 'money',
            'groupKey': null,
            'unitLabel': '元',
            'groups': [
              {'unit': null, 'value': 345.67, 'valueExact': '345.6700'},
            ],
          },
        ],
      };
    }
    if (path.endsWith('/gl/balance-sheet')) {
      return {
        'readScopeVersion': 'scope-1',
        'columns': [
          for (final side in ['asset', 'liability']) ...[
            {
              'key': '${side}Item',
              'label': side == 'asset' ? '资产' : '负债和所有者权益',
              'type': 'text',
            },
            {'key': '${side}LineNo', 'label': '行次', 'type': 'int'},
            {'key': '${side}End', 'label': '期末余额', 'type': 'money'},
            {'key': '${side}Start', 'label': '年初余额', 'type': 'money'},
          ],
        ],
        'columnSearchKeys': ['assetItem', 'liabilityItem'],
        'rows': [
          {
            'assetItem': '  货币资金',
            '__cellStyles': {
              'assetItem': {'fillRgb': '808080'},
            },
            'assetLineNo': 1,
            'assetEnd': 10,
            'assetStart': 5,
            'liabilityItem': '短期借款',
            'liabilityLineNo': 31,
            'liabilityEnd': 10,
            'liabilityStart': 5,
          },
        ],
        'facets': <String, dynamic>{},
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/gl/trial-balance')) {
      return {
        'readScopeVersion': 'scope-1',
        'columns': [
          {'key': 'code', 'label': '科目编码', 'type': 'text'},
          {'key': 'name', 'label': '科目名称', 'type': 'text'},
          {'key': 'currencyName', 'label': '外币名称', 'type': 'text'},
          for (final entry in {
            'openingDebit': '期初借方',
            'openingCredit': '期初贷方',
            'debit': '本期发生借方',
            'credit': '本期发生贷方',
            'closingDebit': '期末借方',
            'closingCredit': '期末贷方',
          }.entries)
            {'key': entry.key, 'label': entry.value, 'type': 'money'},
        ],
        'rows': [
          {
            'code': '1001',
            'name': '库存现金',
            'debit': '10.12345',
            '__rowKind': 'DETAIL',
          },
          {
            'code': '',
            'name': '总合计',
            'debit': '10.12345',
            '__rowKind': 'TOTAL',
          },
        ],
        'columnSearchKeys': ['code', 'name'],
        'facets': <String, dynamic>{},
        'totals': <Map<String, dynamic>>[],
        'page': 1,
        'size': 50,
        'total': 2,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/statements/subcontract')) {
      return {
        'readScopeVersion': 'scope-1',
        'columns': [
          {'key': 'goodsName', 'label': '品名及规格', 'type': 'text'},
          {'key': 'balance', 'label': '整组结存', 'type': 'number'},
          {'key': 'currencyCode', 'label': '加工币别', 'type': 'text'},
          {
            'key': 'processAmount',
            'label': '本币别加工金额',
            'type': 'money',
            'unitKey': 'currencyCode',
          },
          {'key': 'materialPrice', 'label': '材料款单价（待核验）', 'type': 'money'},
          {'key': 'materialAmount', 'label': '材料款金额（待核验）', 'type': 'money'},
        ],
        'columnSearchKeys': [
          'goodsName',
          'balance',
          'currencyCode',
          'processAmount',
        ],
        'rows': [
          {
            'goodsName': '材料',
            'balance': 5,
            'currencyCode': '美金',
            'processAmount': 10,
            'materialPrice': null,
            'materialAmount': null,
          },
        ],
        'facets': {
          'currencyCode': [
            {'value': 'currency-id', 'label': '美金', 'count': 1},
          ],
        },
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    final balance = path.endsWith('other-receivable');
    return {
      'readScopeVersion': 'scope-1',
      'columns': balance
          ? [
              {'key': 'billNo', 'label': '单号', 'type': 'text'},
              {'key': 'billDate', 'label': '日期', 'type': 'date'},
              {'key': 'balance', 'label': '本月结余(KG)', 'type': 'number'},
            ]
          : [
              {'key': 'orderNo', 'label': '销售订单号', 'type': 'text'},
              {'key': 'orderDate', 'label': '订单日期', 'type': 'date'},
              {'key': 'currencyCode', 'label': '币别', 'type': 'text'},
              {
                'key': 'expectedOriginal',
                'label': '未发运待收原币',
                'type': 'money',
                'unitKey': 'currencyCode',
              },
            ],
      'columnSearchKeys': balance
          ? ['billNo', 'billDate', 'balance']
          : ['orderNo', 'orderDate', 'currencyCode', 'expectedOriginal'],
      'rows': [
        balance
            ? {'billNo': 'C2-1', 'billDate': '2026-10-02', 'balance': 4.95}
            : {
                'orderNo': 'SO-1',
                'orderDate': '2026-10-01',
                'currencyCode': '美金',
                'expectedOriginal': 90071992547409.12,
                'expectedOriginalExact': '90071992547409.1234',
              },
      ],
      'facets': {
        'currencyCode': [
          {'value': 'currency-id', 'label': '美金', 'count': 2},
        ],
      },
      'page': parameters['page'] ?? 1,
      'size': 1,
      'total': 2,
      'totalPages': 2,
    };
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
}

Future<void> _awaitCompletePlasticContext(WidgetTester tester) => pumpUntil(
  tester,
  () {
    if (find
        .byKey(const Key('finance-report-context-retry'))
        .evaluate()
        .isNotEmpty) {
      throw TestFailure(
        'The current complete context read reached its real failure outcome.',
      );
    }
    final fields = tester.widgetList<UtenDropdownField>(
      find.byKey(const Key('finance-report-bin')),
    );
    return fields.length == 1 && fields.single.items.length == 1001;
  },
  reason:
      'The current context must publish all1001 rows after its responsive projection completes.',
);
