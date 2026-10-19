import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/hr_profile/pages/hr_profile_change_detail_page.dart';
import 'package:uten_imp/features/hr_profile/pages/hr_profile_changes_list_page.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';
import 'package:uten_imp/features/profile/providers/profile_change_providers.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Api extends ApiClient {
  _Api({this.owner}) : super(Dio());

  final String Function()? owner;
  String status = 'pending';
  final calls = <String>[];
  final reviews = <Map<String, dynamic>>[];

  Map<String, dynamic> get item => {
    'batchId': 'batch-1',
    'employeeId': 'employee-1',
    'employeeName': owner?.call() ?? '待审员工',
    'employeeCode': 'UT-1',
    'departmentName': '生产部',
    'status': status,
    'itemCount': 1,
    'fieldCodes': ['phone'],
    'fieldLabels': ['联系电话'],
    'submittedAt': '2026-10-12T08:00:00+08:00',
    'items': <Map<String, dynamic>>[],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add(path);
    if (path == ApiEndpoints.myProfile) return {};
    if (path.endsWith('/facets')) {
      return {
        'departments': [
          if ((query?['status'] ?? 'pending') == status)
            {
              'value': 'department-1',
              'label': owner?.call() ?? '生产部',
              'count': 1,
            },
        ],
      };
    }
    if (path == ApiEndpoints.hrProfileChanges ||
        path == ApiEndpoints.profileMyChanges) {
      final requestedStatus =
          query?['status'] ??
          (path == ApiEndpoints.hrProfileChanges ? 'pending' : null);
      final matches = requestedStatus == null || requestedStatus == status;
      return {
        'items': [if (matches) item],
        'page': query?['page'] ?? 1,
        'size': 20,
        'totalElements': matches ? 1 : 0,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/batch-1') || path.endsWith('/batch-2')) {
      return {...item, 'batchId': path.split('/').last};
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    expect(path, ApiEndpoints.hrProfileChangeReview('batch-1'));
    final request = Map<String, dynamic>.from(body! as Map);
    reviews.add(request);
    status = request['action'] == 'approve' ? 'applied' : 'rejected';
    return item;
  }
}

class _Badges extends BadgeSummaryNotifier {
  _Badges(this.api);
  final _Api api;
  int refreshCalls = 0;
  BadgeSummary get snapshot => BadgeSummary(
    loaded: true,
    entries: {
      'hrProfileReview': BadgeCounts(api.status == 'pending' ? 1 : 0, 0),
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

MasterDataTableView<HrProfileChangeListItem> _table(WidgetTester tester) =>
    tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<HrProfileChangeListItem>,
      ),
    );

void main() {
  for (final action in ['approve', 'reject']) {
    for (final resourceChanges in [false, true]) {
      testWidgets(
        'HR $action confirmation is invalidated by ${resourceChanges ? 'resource' : 'identity'} A-B-A',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final api = _Api();
          final identity = StateProvider<AuthenticatedScope>(
            (ref) => const AuthenticatedScope(userId: 'A'),
          );
          final resource = StateProvider<String>((ref) => 'batch-1');
          final container = ProviderContainer(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              apiBaseUrlProvider.overrideWithValue(
                'http://hr-test.invalid/api',
              ),
              currentPermissionsProvider.overrideWithValue({
                Perm.profileReview,
              }),
              masterDataSessionKeyProvider.overrideWith(
                (ref) => ref.watch(identity).userId,
              ),
              authenticatedScopeProvider.overrideWith(
                (ref) => ref.watch(identity),
              ),
              sharedPreferencesProvider.overrideWithValue(preferences),
              sessionSnapshotProvider.overrideWith(_Snapshot.new),
              badgeSummaryProvider.overrideWith(() => _Badges(api)),
            ],
          );
          addTearDown(container.dispose);
          final router = GoRouter(
            initialLocation: '/hr/profile-changes/batch-1',
            routes: [
              GoRoute(
                path: '/hr/profile-changes/:id',
                builder: (_, _) => Consumer(
                  builder: (_, ref, _) =>
                      HrProfileChangeDetailPage(batchId: ref.watch(resource)),
                ),
              ),
              GoRoute(
                path: '/hr/profile-changes',
                builder: (_, _) => const Scaffold(body: Text('变更队列')),
              ),
            ],
          );
          addTearDown(router.dispose);
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
          await tester.tap(find.text(action == 'approve' ? '批准' : '驳回').last);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          if (action == 'reject') {
            await tester.enterText(find.byType(EditableText).last, '旧身份输入的原因');
          }
          if (resourceChanges) {
            container.read(resource.notifier).state = 'batch-2';
            await tester.pump();
            container.read(resource.notifier).state = 'batch-1';
          } else {
            container.read(identity.notifier).state = const AuthenticatedScope(
              userId: 'B',
            );
            await tester.pump();
            container.read(identity.notifier).state = const AuthenticatedScope(
              userId: 'A',
            );
          }
          await tester.pumpAndSettle();
          expect(
            find.byType(AlertDialog),
            findsNothing,
            reason: '旧确认或原因必须退出，不能重新生效',
          );
          expect(api.reviews, isEmpty);
          expect(api.status, 'pending');
          // The new current view is usable, and requires a new confirmation.
          await tester.tap(find.text(action == 'approve' ? '批准' : '驳回').last);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          if (action == 'reject') {
            await tester.enterText(find.byType(EditableText).last, '新确认原因');
            await tester.tap(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.text('驳回'),
              ),
            );
          } else {
            await tester.tap(find.text('确认'));
          }
          await tester.pumpAndSettle();
          expect(api.reviews.single['action'], action);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final action in ['approve', 'reject']) {
    testWidgets(
      'HR single $action removes the original request from retained pending queue and badge',
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
            apiBaseUrlProvider.overrideWithValue('http://hr-test.invalid/api'),
            currentPermissionsProvider.overrideWithValue({Perm.profileReview}),
            masterDataSessionKeyProvider.overrideWithValue('reviewer'),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'reviewer'),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
            badgeSummaryProvider.overrideWith(() => badges),
            sessionSnapshotProvider.overrideWith(_Snapshot.new),
          ],
        );
        addTearDown(container.dispose);
        final router = GoRouter(
          initialLocation: '/hr/profile-changes',
          routes: [
            GoRoute(
              path: '/hr/profile-changes',
              builder: (_, _) => const HrProfileChangesListPage(),
            ),
            GoRoute(
              path: '/hr/profile-changes/:id',
              builder: (_, state) => HrProfileChangeDetailPage(
                batchId: state.pathParameters['id']!,
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
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
        expect(_table(tester).items.single.batchId, 'batch-1');
        final initialFacetCalls = api.calls
            .where((path) => path.endsWith('/facets'))
            .length;
        // Keep the source page alive, as the shared back contract permits.
        router.push('/hr/profile-changes/batch-1');
        await tester.pumpAndSettle();
        await tester.tap(find.text(action == 'approve' ? '批准' : '驳回').last);
        await tester.pumpAndSettle();
        if (action == 'reject') {
          await tester.enterText(find.byType(EditableText).last, '号码缺失，请补齐');
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('驳回'),
            ),
          );
        } else {
          await tester.tap(find.text('确认'));
        }
        await tester.pumpAndSettle();
        expect(api.reviews.single['action'], action);
        if (action == 'reject') {
          expect(api.reviews.single['comment'], '号码缺失，请补齐');
        }
        expect(_table(tester).items, isEmpty);
        expect(
          api.calls.where((path) => path.endsWith('/facets')).length,
          greaterThan(initialFacetCalls),
        );
        expect(find.byType(UtenNotificationBadge), findsNothing);
        expect(badges.refreshCalls, greaterThan(0));
        // The same request remains in terminal history under the same batch ID.
        _table(tester).onFilterChanged(
          'status',
          action == 'approve' ? 'applied' : 'rejected',
        );
        await tester.pumpAndSettle();
        expect(_table(tester).items.single.batchId, 'batch-1');
        expect(_table(tester).selectable, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test(
    'all profile change sources refresh for a new identity with the same API client',
    () async {
      final identity = StateProvider<String>((ref) => 'employee-A');
      late ProviderContainer container;
      final api = _Api(owner: () => container.read(identity));
      container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          masterDataSessionKeyProvider.overrideWith(
            (ref) => ref.watch(identity),
          ),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'reviewer'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final providers = [
        myEmployeeProfileProvider,
        myProfileChangesProvider((status: null, page: 1)),
        myProfileChangeDetailProvider('batch-1'),
        hrProfileChangesProvider((status: null, page: 1)),
        hrProfileEmployeePendingProvider('employee-1'),
        hrProfileChangeQueueProvider((
          status: null,
          departmentId: null,
          page: 1,
        )),
        hrProfileChangeFacetsProvider('pending'),
        hrProfileChangeDetailProvider('batch-1'),
      ];
      final subscriptions = [
        for (final provider in providers) container.listen(provider, (_, _) {}),
      ];
      addTearDown(() {
        for (final subscription in subscriptions) {
          subscription.close();
        }
      });
      await Future.wait([
        container.read(myEmployeeProfileProvider.future),
        container.read(
          myProfileChangesProvider((status: null, page: 1)).future,
        ),
        container.read(myProfileChangeDetailProvider('batch-1').future),
        container.read(
          hrProfileChangesProvider((status: null, page: 1)).future,
        ),
        container.read(hrProfileEmployeePendingProvider('employee-1').future),
        container.read(
          hrProfileChangeQueueProvider((
            status: null,
            departmentId: null,
            page: 1,
          )).future,
        ),
        container.read(hrProfileChangeFacetsProvider('pending').future),
        container.read(hrProfileChangeDetailProvider('batch-1').future),
      ]);
      api.calls.clear();
      container.read(identity.notifier).state = 'employee-B';
      await Future<void>.delayed(Duration.zero);
      await Future.wait([
        container.read(myEmployeeProfileProvider.future),
        container.read(
          myProfileChangesProvider((status: null, page: 1)).future,
        ),
        container.read(myProfileChangeDetailProvider('batch-1').future),
        container.read(
          hrProfileChangesProvider((status: null, page: 1)).future,
        ),
        container.read(hrProfileEmployeePendingProvider('employee-1').future),
        container.read(
          hrProfileChangeQueueProvider((
            status: null,
            departmentId: null,
            page: 1,
          )).future,
        ),
        container.read(hrProfileChangeFacetsProvider('pending').future),
        container.read(hrProfileChangeDetailProvider('batch-1').future),
      ]);
      expect(api.calls.length, 8);
      expect(
        container
            .read(myProfileChangeDetailProvider('batch-1'))
            .requireValue
            .employeeName,
        'employee-B',
      );
      expect(
        container
            .read(
              hrProfileChangeQueueProvider((
                status: null,
                departmentId: null,
                page: 1,
              )),
            )
            .requireValue
            .items
            .single
            .employeeName,
        'employee-B',
      );
      expect(
        container
            .read(hrProfileChangeFacetsProvider('pending'))
            .requireValue['departmentName']!
            .single
            .label,
        'employee-B',
      );
    },
  );
}
