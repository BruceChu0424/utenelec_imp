import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/pages/expense_approval_list_page.dart';
import 'package:uten_imp/features/expense/pages/expense_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/filter_segment_tap.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  String status = 'SUBMITTED';
  bool remoteCreated = false;
  int get pendingCount =>
      (status == 'SUBMITTED' ? 1 : 0) + (remoteCreated ? 1 : 0);
  final listCalls = <Map<String, dynamic>>[];
  int facetCalls = 0;
  int summaryCalls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/facets')) {
      facetCalls++;
      return {
        'claimNos': [
          if (query?['queue'] != 'pending' || status == 'SUBMITTED')
            {'value': 'BX1', 'label': 'BX1', 'count': 1},
          if (remoteCreated) {'value': 'BX2', 'label': 'BX2', 'count': 1},
        ],
      };
    }
    if (path.endsWith('/summary')) {
      summaryCalls++;
      return {'pendingCount': pendingCount};
    }
    if (path.endsWith('/mine') || path.endsWith('/pending')) {
      listCalls.add({'path': path, ...?query});
      final statuses = (query?['status'] as String?)?.split(',');
      final matches = path.endsWith('/pending')
          ? status == 'SUBMITTED'
          : statuses == null || statuses.contains(status);
      final matchesCreated =
          remoteCreated &&
          (path.endsWith('/pending') ||
              statuses == null ||
              statuses.contains('SUBMITTED'));
      return {
        'items': [
          if (matches)
            {
              'id': 'claim-1',
              'claimNo': 'BX1',
              'applicantId': 'employee-1',
              'applicantName': '申请人',
              'title': '测试报销',
              'status': status,
              'totalAmount': 30,
              'createdAt': '2026-10-12T08:00:00Z',
              'items': <Map<String, dynamic>>[],
              'version': status == 'SUBMITTED' ? 1 : 2,
            },
          if (matchesCreated)
            {
              'id': 'claim-2',
              'claimNo': 'BX2',
              'applicantId': 'employee-1',
              'applicantName': '申请人',
              'title': '另一终端新建的报销',
              'status': 'SUBMITTED',
              'totalAmount': 50,
              'createdAt': '2026-10-12T08:05:00Z',
              'items': <Map<String, dynamic>>[],
              'version': 1,
            },
        ],
        'page': query?['page'] ?? 1,
        'size': 24,
        'total': (matches ? 1 : 0) + (matchesCreated ? 1 : 0),
        'totalPages': 1,
      };
    }
    throw StateError('unexpected GET $path');
  }
}

class _Badges extends BadgeSummaryNotifier {
  _Badges(this.api);
  final _Api api;
  int refreshCalls = 0;
  BadgeSummary get snapshot => BadgeSummary(
    loaded: true,
    entries: {
      'expenseMine': BadgeCounts(
        api.status == 'REJECTED' ? 1 : 0,
        api.pendingCount,
      ),
      'expenseFinance': BadgeCounts(api.pendingCount, 0),
    },
    facts: {
      BadgeFact.expenseRejected: api.status == 'REJECTED' ? 1 : 0,
      BadgeFact.expensePendingApproval: api.pendingCount,
    },
  );
  @override
  BadgeSummary build() => snapshot;
  @override
  Future<void> refresh() async {
    refreshCalls++;
    state = snapshot;
  }
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

MasterDataTableView<ExpenseClaim> _table(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate(
    (widget) => widget is MasterDataTableView<ExpenseClaim>,
  ),
);

void main() {
  for (final approval in [false, true]) {
    for (final stale in [false, true]) {
      testWidgets(
        '${approval ? 'approval' : 'mine'} queue ${stale ? 'refreshes after remote rejection and stale return' : 'revalidates immediately and shows a remote addition'}',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1200, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final api = _Api();
          final badges = _Badges(api);
          final container = ProviderContainer(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              apiBaseUrlProvider.overrideWithValue(
                'http://expense-test.invalid/api',
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.expenseApply,
                Perm.expenseApprove,
              }),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'user-1'),
              ),
              masterDataSessionKeyProvider.overrideWithValue('user-1'),
              sharedPreferencesProvider.overrideWithValue(preferences),
              badgeSummaryProvider.overrideWith(() => badges),
              sessionSnapshotProvider.overrideWith(_Snapshot.new),
            ],
          );
          addTearDown(container.dispose);
          final path = approval ? '/expense/approval' : '/expense';
          final router = GoRouter(
            initialLocation: path,
            routes: [
              GoRoute(
                path: path,
                builder: (_, _) => approval
                    ? const ExpenseApprovalListPage()
                    : const ExpenseListPage(),
              ),
              GoRoute(
                path: '$path/:id',
                builder: (context, _) => Scaffold(
                  body: TextButton(
                    onPressed: () => context.pop(),
                    child: const Text('返回队列'),
                  ),
                ),
              ),
            ],
          );
          addTearDown(router.dispose);
          addTearDown(
            attachPageResume(
              router,
              container.read(pageResumeProvider.notifier),
            ),
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
          if (!approval) {
            await selectFilterSegment(tester, '处理中');
            await tester.pumpAndSettle();
          }
          expect(_table(tester).items.single.id, 'claim-1');
          final originalCalls = api.listCalls.length;
          final originalFacetCalls = api.facetCalls;
          final originalSummaryCalls = api.summaryCalls;
          _table(tester).onRowTap!(_table(tester).items.single);
          await tester.pumpAndSettle();
          if (stale) {
            // Another role rejected this same claim while this user viewed its
            // detail. No local write-revision shortcut can refresh the list.
            api.status = 'REJECTED';
            await tester.pump(const Duration(seconds: 31));
          } else {
            // A server-side creation has no local write-revision signal and
            // must still appear after even the shortest detail visit.
            api.remoteCreated = true;
          }
          await tester.tap(find.text('返回队列'));
          await tester.pumpAndSettle();
          if (stale) {
            expect(api.listCalls.length, originalCalls + 1);
            expect(_table(tester).items, isEmpty);
            expect(api.facetCalls, originalFacetCalls + 1);
            if (approval) expect(api.summaryCalls, originalSummaryCalls + 1);
            expect(badges.refreshCalls, 1);
            if (!approval) {
              expect(
                api.listCalls.last['status'],
                'SUBMITTED,REVIEWING,APPROVED',
              );
              await selectFilterSegment(tester, '待修订');
              await tester.pumpAndSettle();
              expect(_table(tester).items.single.id, 'claim-1');
              expect(
                _table(tester).items.single.status,
                ExpenseClaimStatus.rejected,
              );
            }
          } else {
            expect(api.listCalls.length, originalCalls + 1);
            expect(_table(tester).items.map((claim) => claim.id), [
              'claim-1',
              'claim-2',
            ]);
            expect(_table(tester).items.last.title, '另一终端新建的报销');
            expect(
              _table(tester).items.last.status,
              ExpenseClaimStatus.submitted,
            );
            expect(api.facetCalls, originalFacetCalls + 1);
            if (approval) expect(api.summaryCalls, originalSummaryCalls + 1);
            expect(badges.refreshCalls, 1);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
