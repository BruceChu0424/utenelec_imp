import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/visitor/models/visitor_application.dart';
import 'package:uten_imp/features/visitor/pages/visitor_home_page.dart';
import 'package:uten_imp/features/visitor/providers/visitor_session_provider.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/features/visitor_approval/pages/my_visitors_page.dart';
import 'package:uten_imp/features/visitor_approval/pages/visitor_approval_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.visitorApprovalFacets) {
      return {
        'statuses': [
          {'value': query?['status'] ?? 'pending', 'count': 1},
        ],
        'departments': <Map<String, dynamic>>[],
      };
    }
    if (path != ApiEndpoints.visitorApproval &&
        path != ApiEndpoints.visitorApprovalAsHost) {
      return const {};
    }
    queries.add((path, Map.of(query ?? const {})));
    final status =
        query?['status'] ??
        (path == ApiEndpoints.visitorApprovalAsHost
            ? 'hostReviewing'
            : 'pending');
    return {
      'items': [
        for (final code in (status as String).split(','))
          {
            'id': 'visitor-app-$code',
            'visitorName': '访客$code',
            'visitPurpose': '来访',
            'status': code,
            'plannedVisitAt': '2026-10-11T10:00:00+08:00',
            'appliedAt': '2026-10-10T10:00:00+08:00',
          },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
    };
  }
}

void main() {
  testWidgets(
    'visitor home separates every terminal state from its default active requests',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _VisitorRepo();
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            visitorRepositoryProvider.overrideWithValue(repository),
            visitorSessionProvider.overrideWith(_VisitorSession.new),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: VisitorHomePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.statuses.last, 'pending,hostReviewing');
      final l10n = AppLocalizations.of(
        tester.element(find.byType(VisitorHomePage)),
      );
      expect(
        tester.getTopLeft(find.byType(UtenFilterToolbar<VisitorFilter>)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(UtenAppBar)).dy),
      );
      await tester.tap(find.text(l10n.visitorFilterApproved));
      await tester.pumpAndSettle();
      expect(repository.statuses.last, 'approved');
      await tester.tap(find.text('历史单据'));
      await tester.pumpAndSettle();
      expect(repository.statuses.last, 'checkedIn,rejected,cancelled');
      expect(find.text('全部在办'), findsNothing);
      await tester.tap(
        find.text(
          AppLocalizations.of(
            tester.element(find.byType(VisitorHomePage)),
          ).visitorFilterPending,
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.statuses.last, 'pending,hostReviewing');
      await tester.binding.setSurfaceSize(const Size(390, 850));
      await tester.pumpAndSettle();
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      expect(
        tester.getCenter(find.text(l10n.visitorApplyNew)).dy,
        greaterThan(425),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final host in [false, true]) {
    for (final (status, label) in [
      ('checkedIn', '已签到'),
      ('cancelled', '已取消'),
      ('rejected', '已拒绝'),
    ]) {
      testWidgets('${host ? 'host' : 'HR'} can read $status without actions', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final api = _Api();
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              currentPermissionsProvider.overrideWithValue({
                host ? Perm.visitorHostConfirm : Perm.visitorApprove,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              fixedBadgeSummaryOverride(),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: host
                  ? const MyVisitorsPage()
                  : const VisitorApprovalListPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byKey(
              Key(
                host
                    ? 'my-visitors-status-segments'
                    : 'visitor-approval-segments',
              ),
            ),
            matching: find.text('历史单据'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          api.queries.last.$1,
          host
              ? ApiEndpoints.visitorApprovalAsHost
              : ApiEndpoints.visitorApproval,
        );
        expect(api.queries.last.$2['status'], 'checkedIn,rejected,cancelled');
        expect(api.queries.last.$2['page'], 1);
        var table = tester.widget<MasterDataTableView<VisitorApplication>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<VisitorApplication>,
          ),
        );
        expect(table.items.map((item) => item.status.name), [
          'checkedIn',
          'rejected',
          'cancelled',
        ]);
        table.onFilterChanged('status', status);
        await tester.pumpAndSettle();
        expect(api.queries.last.$2['status'], status);
        table = tester.widget<MasterDataTableView<VisitorApplication>>(
          find.byType(MasterDataTableView<VisitorApplication>),
        );
        expect(table.items.single.status.name, status);
        expect(find.text(label), findsWidgets);
        expect(table.selectable, isFalse);
        expect(table.batchActionsBuilder, isNull);
        if (host) {
          expect(table.rowMenuBuilder!(table.items.single), isEmpty);
          expect(
            table.facets['status']!.map((bucket) => bucket.value),
            containsAll(['checkedIn', 'cancelled']),
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _VisitorSession extends VisitorSessionNotifier {
  @override
  VisitorSessionState build() => const VisitorSessionState();
}

class _VisitorRepo extends Fake implements VisitorRepository {
  final statuses = <String?>[];
  @override
  Future<PagedResult<VisitorApplication>> myApplications({
    String? status,
    int page = 1,
    int size = 20,
  }) async {
    statuses.add(status);
    return PagedResult(
      items: const [],
      page: page,
      size: size,
      total: 0,
      totalPages: 0,
    );
  }
}
