import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';

void main() {
  final timings = <Map<String, Object>>[];
  final scenarios = <(String, Widget)>[
    for (final kind in PurchaseDocType.values)
      (
        'purchase/${kind.name}',
        PurchaseDocListPage(docType: kind, initialStatus: 'draft'),
      ),
    for (final kind in SalesDocType.values.where(
      (kind) => kind != SalesDocType.otherShipment,
    ))
      (
        'sales/${kind.name}',
        SalesDocListPage(docType: kind, initialStatus: 'draft'),
      ),
    for (final kind in FinanceDocType.values)
      (
        'finance/${kind.name}',
        FinanceDocListPage(docType: kind, initialStatus: 'draft'),
      ),
    for (final kind in StockDocType.values.where(
      (kind) => !kind.isLegacyReadOnly,
    ))
      (
        'stock/${kind.name}',
        StockDocListPage(docType: kind, initialStatus: 'draft'),
      ),
  ];
  for (final scenario in scenarios) {
    testWidgets(
      '${scenario.$1} measures real page first rows and category requests',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _Api();
        final router = GoRouter(
          routes: [GoRoute(path: '/', builder: (_, _) => scenario.$2)],
        );
        addTearDown(router.dispose);
        final clock = Stopwatch()..start();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'timing-fixture'),
              ),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue({
                for (final kind in DraftDocKind.values) kind.viewPerm,
              }),
              isSuperAdminProvider.overrideWithValue(true),
              fixedBadgeSummaryOverride(),
            ],
            child: MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
          ),
        );
        final finder = find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView,
        );
        var frames = 0;
        MasterDataTableView<dynamic>? table;
        while (frames < 20) {
          await tester.pump(const Duration(milliseconds: 16));
          frames++;
          if (finder.evaluate().length != 1) continue;
          table = tester.widget<MasterDataTableView<dynamic>>(finder);
          if (table.items.isNotEmpty && !table.isLoading) break;
        }
        final firstRowsMs = clock.elapsedMicroseconds / 1000;
        expect(table, isNotNull);
        expect(table!.items, hasLength(1));
        expect(table.isLoading, isFalse);
        await tester.pumpAndSettle();
        timings.add({
          'page': scenario.$1,
          'firstRowsMs': firstRowsMs,
          'frames': frames,
          'categoryHttpReads': api.categoryReads,
          'rows': table.items.length,
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  tearDownAll(() {
    final output = File('build/category-page-entry-timings.json');
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'fixture':
            'Actual Flutter list pages, synthetic nonempty DTOs, immediate isolated API; wall-clock build/layout timings, no company-server latency claim',
        'pages': timings,
      }),
    );
  });
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  int categoryReads = 0;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/documents/status-counts') {
      categoryReads++;
      return {'DRAFT': 1, 'ACTIONABLE_DRAFT': 1, 'APPROVED': 0, 'REVERSED': 0};
    }
    return {
      'items': [
        {
          'id': 'doc-1',
          'billNo': 'TIMING-FIXTURE-1',
          'billDate': '2026-11-01',
          'status': 0,
          'clientId': 'party-1',
          'supplierId': 'party-1',
        },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalElements': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}
