import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_document_lifecycle_filter.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/list_refresh_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/filter_segment_tap.dart';

void main() {
  testWidgets(
    'expense confirmation hub card reaches the scoped pending deep link',
    (tester) async {
      final api = _ExpenseLifecycleApi();
      final router = await _pump(
        tester,
        api,
        FinanceDocType.expense,
        hub: true,
      );
      expect(api.lists, isEmpty);
      await tester.tap(find.text('费用单财务确认'));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['status'],
        'pending-gl-confirmation',
      );
      expect(api.lists.last['view'], 'ACTIVE');
      expect(api.lists.last['status'], 1);
      expect(_table(tester).items.single.glStatus, 1);
    },
  );

  testWidgets(
    'confirmation refresh signal retains scope and recovers the last pending page',
    (tester) async {
      final api = _ExpenseLifecycleApi();
      await _pump(tester, api, FinanceDocType.expense);
      await selectFilterSegment(tester, '待财务确认');
      await tester.pumpAndSettle();
      await _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      final badge =
          container.read(badgeSummaryProvider.notifier)
              as FixedBadgeSummaryNotifier;
      final refreshBefore = badge.refreshCalls;
      _table(tester).onRowTap!(_table(tester).items.single);
      await tester.pumpAndSettle();
      await tester.tap(find.text('confirm fixture'));
      await tester.pumpAndSettle();
      expect(badge.refreshCalls, greaterThan(refreshBefore));
      expect(api.lists.last['page'], 1);
      expect(api.lists.last['view'], 'ACTIVE');
      expect(api.lists.last['status'], 1);
      expect(_table(tester).currentPage, 1);
      expect(_table(tester).items.single.glStatus, 1);
    },
  );
  testWidgets(
    'view-only staff see pending GL work; paging, facets and clearing retain lifecycle',
    (tester) async {
      final api = _ExpenseLifecycleApi();
      await _pump(tester, api, FinanceDocType.expense);
      expect(
        api.lists,
        isEmpty,
        reason: 'unselected category must not request all records',
      );
      expect(
        tester
            .widget<UtenDocumentLifecycleFilter>(
              find.byType(UtenDocumentLifecycleFilter),
            )
            .ongoingCount,
        2,
      );

      await selectFilterSegment(tester, '待财务确认');
      await tester.pumpAndSettle();
      expect(api.lists.last, containsPair('view', 'ACTIVE'));
      expect(api.lists.last, containsPair('status', 1));
      expect(api.lists.last, containsPair('hf.recordOrigin', 'CURRENT'));
      expect(api.facets.last['view'], 'ACTIVE');
      expect(api.facets.last['status'], 1);
      var table = _table(tester);
      expect(table.items.single.glStatus, 1);
      expect(
        table.columns
            .firstWhere((column) => column.key == 'status')
            .value(table.items.single),
        '待财务确认',
      );
      expect(table.selectable, isFalse);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is FormDraftCategoryTable<FinanceDocListItem>,
        ),
        findsNothing,
      );
      expect(
        table.facets['status']!.map((bucket) => bucket.label),
        contains('待财务确认'),
      );
      table.onFilterChanged('status', null);
      await tester.pumpAndSettle();
      expect(api.lists.last['view'], 'ACTIVE');
      expect(
        api.lists.last['status'],
        1,
        reason: 'clearing retains the pending-confirmation parent',
      );
      await _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      expect(api.lists.last['page'], 2);
      expect(api.lists.last['view'], 'ACTIVE');
      expect(api.facets.last['status'], 1);

      await selectFilterSegment(tester, '历史单据');
      await tester.pumpAndSettle();
      expect(api.lists.last['view'], 'HISTORY');
      expect(api.lists.last.containsKey('status'), isFalse);
      expect(api.lists.last.containsKey('hf.recordOrigin'), isFalse);
      table = _table(tester);
      expect(table.items.single.glStatus, 2);
      expect(
        table.facets['status']!.map((bucket) => bucket.value),
        isNot(contains('0')),
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is FormDraftCategoryTable<FinanceDocListItem>,
        ),
        findsNothing,
      );
      table.onFilterChanged('status', '1');
      await tester.pumpAndSettle();
      _table(tester).onFilterChanged('status', null);
      await tester.pumpAndSettle();
      expect(api.lists.last['view'], 'HISTORY');
      expect(api.lists.last.containsKey('status'), isFalse);
      await _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      expect(api.lists.last['page'], 2);
      expect(api.lists.last['view'], 'HISTORY');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late pending confirmation response cannot replace completed history',
    (tester) async {
      final api = _ExpenseLifecycleApi()..pendingActive = Completer();
      await _pump(tester, api, FinanceDocType.expense);
      await selectFilterSegment(tester, '待财务确认');
      await tester.pump();
      expect(api.lists.last['view'], 'ACTIVE');
      await selectFilterSegment(tester, '历史单据');
      await tester.pumpAndSettle();
      expect(_table(tester).items.single.glStatus, 2);
      api.pendingActive!.complete(_ExpenseLifecycleApi.page('ACTIVE', 1));
      await tester.pumpAndSettle();
      expect(_table(tester).items.single.glStatus, 2);
      expect(_table(tester).items.single.id, 'history-1');
      expect(tester.takeException(), isNull);
    },
  );

  for (final type in FinanceDocType.values.where(
    (type) => type != FinanceDocType.expense,
  )) {
    testWidgets('${type.name} has no invented confirmation workflow', (
      tester,
    ) async {
      final api = _ExpenseLifecycleApi();
      await _pump(tester, api, type);
      expect(find.text('待财务确认'), findsNothing);
      await selectFilterSegment(tester, '草稿');
      await tester.pumpAndSettle();
      expect(api.lists.last['status'], 0);
      expect(api.lists.last.containsKey('view'), isFalse);
      expect(api.facets.last.containsKey('view'), isFalse);
    });
  }
}

MasterDataTableView<FinanceDocListItem> _table(WidgetTester tester) =>
    tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<FinanceDocListItem>,
      ),
    );

Future<GoRouter> _pump(
  WidgetTester tester,
  _ExpenseLifecycleApi api,
  FinanceDocType type, {
  bool hub = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: hub ? '/finance' : '/list',
    routes: [
      GoRoute(path: '/finance', builder: (_, _) => const FinanceHubPage()),
      GoRoute(
        path: '/finance/expenses',
        builder: (_, state) => FinanceDocListPage(
          docType: FinanceDocType.expense,
          initialStatus: state.uri.queryParameters['status'],
        ),
      ),
      GoRoute(
        path: '/finance/expenses/:id',
        builder: (_, _) => Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () {
                api.pendingTotal = 1;
                bumpListRefresh(ref, 'finance:expense');
                context.pop();
              },
              child: const Text('confirm fixture'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/list',
        builder: (_, _) => FinanceDocListPage(docType: type),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({'finance_expense:view'}),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
  final notifier = container.read(pageResumeProvider.notifier);
  addTearDown(attachPageResume(router, notifier));
  bumpPageResumeState(notifier, hub ? '/finance' : '/list');
  await tester.pumpAndSettle();
  return router;
}

class _ExpenseLifecycleApi extends ApiClient {
  _ExpenseLifecycleApi() : super(Dio());
  final lists = <Map<String, dynamic>>[];
  final facets = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? pendingActive;
  int pendingTotal = 2;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final request = Map<String, dynamic>.from(query ?? const {});
    if (path == '/documents/status-counts') {
      return {
        'ACTIONABLE_DRAFT': 1,
        'DRAFT': 1,
        'ACTIONABLE_PENDING_GL_CONFIRMATION': 2,
        'PENDING_GL_CONFIRMATION': 2,
      };
    }
    if (path.endsWith('/facets')) {
      facets.add(request);
      return {
        'billNo': [
          {'value': 'YF-test', 'label': 'YF-test', 'count': 2},
        ],
      };
    }
    if (path.startsWith('/finance/')) {
      lists.add(request);
      if (request['view'] == 'ACTIVE' && pendingActive != null) {
        return pendingActive!.future;
      }
      return page(
        request['view'] as String? ?? 'ACTIVE',
        request['page'] as int? ?? 1,
        total: request['view'] == 'ACTIVE' ? pendingTotal : 2,
      );
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  static Map<String, dynamic> page(String view, int number, {int total = 2}) =>
      {
        'items': [
          if (number <= total)
            {
              'id': '${view == 'HISTORY' ? 'history' : 'pending'}-$number',
              'billNo': 'YF-$number',
              'billDate': '2026-10-15',
              'status': 1,
              'glStatus': view == 'HISTORY' ? 2 : 1,
            },
        ],
        'page': number,
        'size': 1,
        'total': total,
        'totalPages': total,
      };
}
