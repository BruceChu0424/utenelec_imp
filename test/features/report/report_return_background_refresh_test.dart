import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_report_config.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  Completer<Map<String, dynamic>>? held;
  bool requestedHeld = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.contains('/reports/')) return {};
    final pending = held;
    if (pending != null) {
      requestedHeld = true;
      held = null;
      return pending.future;
    }
    return _report('ACCEPTED', (query?['page'] as int?) ?? 1);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};
}

Map<String, dynamic> _report(String prefix, int page) => {
  'columns': [
    {'key': 'proof', 'label': '记录', 'type': 'text', 'width': 280},
  ],
  'rows': [
    for (var row = 0; row < 50; row++)
      {'id': '$page-$row', 'proof': '$prefix-$page-$row'},
  ],
  'facets': <String, dynamic>{},
  'page': page,
  'total': 150,
  'totalPages': 3,
};

void main() {
  final pages = <String, Widget>{
    'sales': const SalesReportPage(kind: SalesReportKind.summary),
    'purchase': const PurchaseReportTablePage(kind: PurchaseReportKind.summary),
    'warehouse': const WarehouseReportTablePage(
      kind: WarehouseReportKind.summary,
    ),
    'subcontract': const SubcontractReportTablePage(
      kind: SubcontractReportKind.summary,
    ),
    'production': const ProductionReportPage(
      kind: ProductionReportKind.summary,
    ),
    'finance': const FinanceReportTablePage(cardId: 'detail'),
  };
  for (final entry in pages.entries) {
    testWidgets(
      '${entry.key} return revalidates without resetting table or scroll',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _Api();
        final container = ProviderContainer(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
            sessionSnapshotProvider.overrideWith(_Snapshots.new),
            sharedPreferencesProvider.overrideWithValue(preferences),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'reader'),
            ),
            currentPermissionsProvider.overrideWithValue(const {}),
            isSuperAdminProvider.overrideWithValue(false),
            fixedBadgeSummaryOverride(badgeSummaryFixture()),
          ],
        );
        addTearDown(container.dispose);
        final router = GoRouter(
          initialLocation: '/report',
          routes: [
            GoRoute(path: '/report', builder: (_, _) => entry.value),
            GoRoute(
              path: '/detail',
              builder: (_, _) => const Scaffold(body: Text('详情')),
            ),
          ],
        );
        addTearDown(router.dispose);
        addTearDown(
          attachPageResume(router, container.read(pageResumeProvider.notifier)),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tableFinder = find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<Map<String, dynamic>>,
        );
        MasterDataTableView<Map<String, dynamic>> table() =>
            tester.widget(tableFinder);
        await table().onPageChange!(2);
        await tester.pumpAndSettle();
        expect(table().currentPage, 2);
        final originalState = tester.state(tableFinder);
        final position = Scrollable.of(
          tester.element(find.text('ACCEPTED-2-0')),
          axis: Axis.vertical,
        ).position;
        position.jumpTo(220);
        await tester.pumpAndSettle();
        final pixels = position.pixels;

        Future<Completer<Map<String, dynamic>>> returnWithPendingRead() async {
          router.push<void>('/detail');
          await tester.pumpAndSettle();
          final pending = Completer<Map<String, dynamic>>();
          api.held = pending;
          api.requestedHeld = false;
          router.pop();
          for (var frame = 0; frame < 20 && !api.requestedHeld; frame++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(api.requestedHeld, isTrue);
          // The request starts from a post-frame resume callback; its setState
          // is visible in the following frame, while I/O is still held.
          await tester.pump();
          expect(table().isLoading, isFalse);
          expect(table().isRefreshing, isTrue);
          expect(tester.state(tableFinder), same(originalState));
          expect(position.pixels, pixels);
          return pending;
        }

        final fresh = await returnWithPendingRead();
        fresh.complete(_report('FRESH', 2));
        await tester.pumpAndSettle();
        expect(table().items.first['proof'], 'FRESH-2-0');
        expect(tester.state(tableFinder), same(originalState));
        expect(position.pixels, pixels);

        final failed = await returnWithPendingRead();
        failed.completeError(ApiException('NETWORK', 'offline'));
        await tester.pumpAndSettle();
        expect(table().items.first['proof'], 'FRESH-2-0');
        expect(table().refreshError, 'offline');
        expect(tester.state(tableFinder), same(originalState));
        expect(position.pixels, pixels);

        final denied = await returnWithPendingRead();
        denied.completeError(ApiException('FORBIDDEN', 'no longer authorized'));
        await tester.pumpAndSettle();
        expect(tableFinder, findsNothing);
        expect(find.textContaining('FRESH-2-'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
