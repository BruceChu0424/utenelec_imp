import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/layout/uten_refresh_scope.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_list_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_list_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_stock_doc_segment.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  final pages = <String, Widget>{
    'sales': const SalesDocListPage(
      docType: SalesDocType.quote,
      initialStatus: 'draft',
    ),
    'finance': const FinanceDocListPage(
      docType: FinanceDocType.receipt,
      initialStatus: 'draft',
    ),
    'stock': const StockDocListPage(
      docType: StockDocType.draw,
      initialStatus: 'draft',
    ),
    'plan': const ProductionPlanListPage(initialStatus: 'draft'),
    'daily report': const ProductionDailyReportListPage(initialStatus: 'draft'),
    'stock segment': const _SegmentHost(),
  };
  for (final entry in pages.entries) {
    for (final failOld in [false, true]) {
      testWidgets(
        '${entry.key} replaces a refresh wait and fences stale ${failOld ? 'error' : 'data'}',
        (tester) async {
          final api = _Api();
          await _mount(tester, api, entry.value);
          await tester.pumpAndSettle();
          if (entry.key == 'stock segment') {
            await tester.tap(find.text('草稿').first);
            await tester.pumpAndSettle();
          }
          expect(find.text('ACCEPTED'), findsOneWidget);
          final old = Completer<Map<String, dynamic>>();
          api.held = old;
          await tester.tap(find.byType(UtenRefreshButton));
          await tester.pump();
          await tester.pump();
          expect(
            api.held,
            isNull,
            reason: 'the button must start the actual list GET',
          );
          expect(find.byType(CircularProgressIndicator), findsWidgets);
          final table = tester.widget<MasterDataTableView<dynamic>>(
            find.byWidgetPredicate((widget) => widget is MasterDataTableView),
          );
          api.bill = 'FRESH';
          table.onSortChange!('billNo', false);
          await tester.pumpAndSettle();
          expect(find.text('FRESH'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(
            old.isCompleted,
            isFalse,
            reason: 'query replacement only releases the obsolete UI wait',
          );
          if (failOld) {
            old.completeError(ApiException('FORBIDDEN', 'STALE ERROR'));
          } else {
            old.complete(_page('STALE'));
          }
          await tester.pumpAndSettle();
          expect(find.text('FRESH'), findsOneWidget);
          expect(find.text('STALE'), findsNothing);
          expect(find.text('STALE ERROR'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  final typeChanges = <String, (Widget, Widget)>{
    'sales': (
      pages['sales']!,
      const SalesDocListPage(docType: SalesDocType.shipment),
    ),
    'finance': (
      pages['finance']!,
      const FinanceDocListPage(docType: FinanceDocType.payment),
    ),
    'stock': (
      pages['stock']!,
      const StockDocListPage(docType: StockDocType.transfer),
    ),
    'stock segment': (
      pages['stock segment']!,
      const _SegmentHost(docType: StockDocType.transfer),
    ),
  };
  for (final entry in typeChanges.entries) {
    for (final failOld in [false, true]) {
      testWidgets(
        '${entry.key} drops an old ${failOld ? 'error' : 'response'} when a new type needs no GET',
        (tester) async {
          final api = _Api();
          final selected = ValueNotifier(entry.value.$1);
          addTearDown(selected.dispose);
          await _mount(
            tester,
            api,
            ValueListenableBuilder<Widget>(
              valueListenable: selected,
              builder: (_, page, _) => page,
            ),
          );
          await tester.pumpAndSettle();
          if (entry.key == 'stock segment') {
            await tester.tap(find.text('草稿').first);
            await tester.pumpAndSettle();
          }
          final old = Completer<Map<String, dynamic>>();
          api.held = old;
          await tester.tap(find.byType(UtenRefreshButton));
          await tester.pump();
          await tester.pump();
          expect(api.held, isNull);
          final requests = api.rowRequests;
          selected.value = entry.value.$2;
          await tester.pumpAndSettle();
          expect(
            api.rowRequests,
            requests,
            reason: 'unselected type must not query all documents',
          );
          expect(find.text('ACCEPTED'), findsNothing);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(old.isCompleted, isFalse);
          if (failOld) {
            old.completeError(ApiException('FORBIDDEN', 'STALE ERROR'));
          } else {
            old.complete(_page('STALE'));
          }
          await tester.pumpAndSettle();
          expect(find.text('STALE'), findsNothing);
          expect(find.text('STALE ERROR'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

Future<void> _mount(WidgetTester tester, _Api api, Widget page) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => page)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
}

Map<String, dynamic> _page(String bill) => {
  'items': [
    {'id': bill, 'billNo': bill, 'billDate': '2026-10-13', 'status': 0},
  ],
  'page': 1,
  'size': 20,
  'total': 1,
  'totalPages': 1,
};

class _Api extends ApiClient {
  _Api() : super(Dio());
  Completer<Map<String, dynamic>>? held;
  String bill = 'ACCEPTED';
  int rowRequests = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/documents/status-counts') {
      return {'ACTIONABLE_DRAFT': 1, 'DRAFT': 1};
    }
    if (const {
          '/sales/quotes',
          '/finance/receipts',
          '/stock/docs',
          '/production/plans',
          '/production/daily-reports',
        }.contains(path) &&
        query?['size'] != 1) {
      rowRequests++;
      final pending = held;
      held = null;
      return pending?.future ?? _page(bill);
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

class _SegmentHost extends StatefulWidget {
  const _SegmentHost({this.docType = StockDocType.draw});
  final StockDocType docType;
  @override
  State<_SegmentHost> createState() => _SegmentHostState();
}

class _SegmentHostState extends State<_SegmentHost> {
  final refresh = UtenRefreshController();
  int tick = 0;
  @override
  void dispose() {
    refresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UtenRefreshScope(
    controller: refresh,
    child: Scaffold(
      appBar: AppBar(
        actions: [
          UtenRefreshButton(
            onRefresh: () => refresh.run(() => setState(() => tick++)),
          ),
        ],
      ),
      body: WarehouseStockDocSegment(
        docType: widget.docType,
        refreshTick: tick,
      ),
    ),
  );
}
