import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/router/route_transition_tracker.dart';
import 'package:uten_imp/features/hr_task/models/hr_task_summary.dart';
import 'package:uten_imp/features/hr_task/pages/hr_workbench_page.dart';
import 'package:uten_imp/features/hr_task/pages/hr_task_list_page.dart';
import 'package:uten_imp/features/hr_task/widgets/hr_task_widgets.dart';
import 'package:uten_imp/features/hr_task/providers/hr_task_summary_provider.dart';
import 'package:uten_imp/features/hr_task/repositories/hr_task_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/memory_cas_storage.dart';

class _Repository extends Fake implements HrTaskRepository {
  final requests = <Completer<HrTaskSummary>>[];

  @override
  Future<HrTaskSummary> summary() {
    final request = Completer<HrTaskSummary>();
    requests.add(request);
    return request.future;
  }
}

HrTaskSummary _summary(String name, {int count = 1}) => HrTaskSummary(
  generatedAt: name,
  probationMonths: 3,
  confirmToday: const [],
  confirmUpcoming: const [],
  confirmOverdue: const [],
  unconfirmedLegacyCount: 0,
  birthdayToday: const [],
  birthdayUpcoming: const [],
  anniversaryToday: const [],
  newHires: const [],
  identityReview: [
    for (var i = 0; i < count; i++)
      HrTaskItem(
        employeeId: '$name-$i',
        code: 'E$i',
        name: name,
        days: 0,
        claimedByName: name,
        claimedByMe: true,
      ),
  ],
  badgeCount: count,
  taskCounts: {'identity': count},
);

void main() {
  for (final silent in [true, false]) {
    test(
      'initial build preserves accepted data only for a ${silent ? 'silent' : 'visible'} failed later refresh',
      () async {
        final repository = _Repository();
        final container = ProviderContainer(
          overrides: [
            hrTaskRepositoryProvider.overrideWithValue(repository),
            masterDataSessionKeyProvider.overrideWithValue('A'),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'A'),
            ),
            fixedBadgeSummaryOverride(),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(hrTaskSummaryProvider, (_, _) {});
        addTearDown(subscription.close);
        final notifier = container.read(hrTaskSummaryProvider.notifier);
        final accepted = notifier.refresh();
        repository.requests[1].complete(_summary('accepted B', count: 2));
        await accepted;
        final failing = silent ? notifier.reloadSilently() : notifier.refresh();
        final failure = StateError('latest C failed');
        repository.requests[2].completeError(failure);
        await failing;
        repository.requests[0].complete(_summary('stale initial A', count: 9));
        await Future<void>.delayed(Duration.zero);
        final current = container.read(hrTaskSummaryProvider);
        if (silent) {
          expect(current.requireValue.generatedAt, 'accepted B');
          expect(current.hasError, isFalse);
        } else {
          expect(current.hasError, isTrue);
          expect(current.error, same(failure));
        }
      },
    );
  }

  test(
    'initial build still exposes a failed silent read when no data was accepted',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          hrTaskRepositoryProvider.overrideWithValue(repository),
          masterDataSessionKeyProvider.overrideWithValue('A'),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'A'),
          ),
          fixedBadgeSummaryOverride(),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(hrTaskSummaryProvider, (_, _) {});
      addTearDown(subscription.close);
      final outcome = container
          .read(hrTaskSummaryProvider.future)
          .then<Object>((value) => value, onError: (Object error) => error);
      final failing = container
          .read(hrTaskSummaryProvider.notifier)
          .reloadSilently();
      final failure = StateError('no accepted data');
      repository.requests[1].completeError(failure);
      await failing;
      repository.requests[0].complete(_summary('stale initial A'));
      expect(await outcome, same(failure));
      expect(container.read(hrTaskSummaryProvider).hasError, isTrue);
    },
  );

  test('initial HR summary cannot replace a newer manual refresh', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        hrTaskRepositoryProvider.overrideWithValue(repository),
        masterDataSessionKeyProvider.overrideWithValue('A'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'A'),
        ),
        fixedBadgeSummaryOverride(),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(hrTaskSummaryProvider, (_, _) {});
    addTearDown(subscription.close);
    final newer = container.read(hrTaskSummaryProvider.notifier).refresh();
    repository.requests[1].complete(_summary('newer manual refresh', count: 2));
    await newer;
    expect(
      container.read(hrTaskSummaryProvider).requireValue.generatedAt,
      'newer manual refresh',
    );
    repository.requests[0].complete(_summary('stale initial build', count: 9));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(hrTaskSummaryProvider).requireValue.generatedAt,
      'newer manual refresh',
    );
    expect(container.read(hrTaskSummaryProvider).requireValue.badgeCount, 2);
  });

  for (final fails in [false, true]) {
    test(
      'older HR refresh ${fails ? 'failure' : 'success'} cannot replace a post-write summary',
      () async {
        final repository = _Repository();
        final container = ProviderContainer(
          overrides: [
            hrTaskRepositoryProvider.overrideWithValue(repository),
            masterDataSessionKeyProvider.overrideWithValue('A'),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'A'),
            ),
            fixedBadgeSummaryOverride(),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(hrTaskSummaryProvider, (_, _) {});
        addTearDown(subscription.close);
        repository.requests[0].complete(_summary('initial'));
        await container.read(hrTaskSummaryProvider.future);

        final older = container.read(hrTaskSummaryProvider.notifier).refresh();
        // The employee lifecycle write triggers the same silent refresh as a
        // successful registration in an employee detail page.
        container.read(lastDataWriteProvider.notifier).state = (
          seq: 1,
          path: '/org/employees/E1/confirm',
        );
        repository.requests[2].complete(_summary('after confirm', count: 2));
        await Future<void>.delayed(Duration.zero);
        if (fails) {
          repository.requests[1].completeError(
            StateError('old request failed'),
          );
        } else {
          repository.requests[1].complete(_summary('before confirm', count: 9));
        }
        await older;
        expect(
          container.read(hrTaskSummaryProvider).requireValue.generatedAt,
          'after confirm',
        );
        expect(
          container.read(hrTaskSummaryProvider).requireValue.badgeCount,
          2,
        );
        expect(
          (container.read(badgeSummaryProvider.notifier)
                  as FixedBadgeSummaryNotifier)
              .refreshCalls,
          1,
        );
      },
    );
  }

  test('older completion does not finish a newer visible refresh', () async {
    final repository = _Repository();
    final container = ProviderContainer(
      overrides: [
        hrTaskRepositoryProvider.overrideWithValue(repository),
        masterDataSessionKeyProvider.overrideWithValue('A'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'A'),
        ),
        fixedBadgeSummaryOverride(),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(hrTaskSummaryProvider, (_, _) {});
    addTearDown(subscription.close);
    repository.requests[0].complete(_summary('initial'));
    await container.read(hrTaskSummaryProvider.future);
    final notifier = container.read(hrTaskSummaryProvider.notifier);
    final older = notifier.refresh();
    final newer = notifier.refresh();
    repository.requests[1].complete(_summary('old'));
    await older;
    expect(container.read(hrTaskSummaryProvider).isLoading, isTrue);
    repository.requests[2].complete(_summary('new'));
    await newer;
    expect(
      container.read(hrTaskSummaryProvider).requireValue.generatedAt,
      'new',
    );
  });

  for (final permissionChange in [false, true]) {
    test(
      'HR clears ${permissionChange ? 'permission' : 'impersonation'} scope and rejects late prior rows',
      () async {
        final repository = _Repository();
        final key = StateProvider<String>((ref) => 'A');
        final scope = StateProvider<AuthenticatedScope>(
          (ref) => const AuthenticatedScope(userId: 'A'),
        );
        final container = ProviderContainer(
          overrides: [
            hrTaskRepositoryProvider.overrideWithValue(repository),
            masterDataSessionKeyProvider.overrideWith((ref) => ref.watch(key)),
            authenticatedScopeProvider.overrideWith((ref) => ref.watch(scope)),
            fixedBadgeSummaryOverride(),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(hrTaskSummaryProvider, (_, _) {});
        addTearDown(subscription.close);
        repository.requests[0].complete(_summary('old employee'));
        await container.read(hrTaskSummaryProvider.future);
        final older = container
            .read(hrTaskSummaryProvider.notifier)
            .reloadSilently();
        if (permissionChange) {
          container.read(key.notifier).state = 'A|pii permission removed';
        } else {
          container.read(scope.notifier).state = const AuthenticatedScope(
            userId: 'A',
            actorId: 'admin',
            readOnly: true,
          );
        }
        await Future<void>.delayed(Duration.zero);
        // Riverpod 3：AsyncNotifier 元素在世期间无法清空 previous value——reload
        // 保留旧快照仅供 skipLoadingOnReload 渐进渲染（v3 起 when 默认渲染 reload
        // 的骨架屏，工作台不再呈现旧身仧行；见同文件 HR workbench 页面级用例）。
        // 此处锁「身份一变立即进入重载」，新身份数据落地后原子替换，旧响应晚到
        // 被世代号拒收（下方两条 requireValue 断言）。
        expect(
          container.read(hrTaskSummaryProvider).isReloading,
          isTrue,
          reason: '切换身份/权限必须立即进入重载过渡',
        );
        repository.requests[2].complete(_summary('current employee', count: 0));
        await container.read(hrTaskSummaryProvider.future);
        repository.requests[1].complete(_summary('old employee', count: 9));
        await older;
        expect(
          container.read(hrTaskSummaryProvider).requireValue.identityReview,
          isEmpty,
        );
        expect(
          container.read(hrTaskSummaryProvider).requireValue.badgeCount,
          0,
        );
      },
    );
  }

  testWidgets(
    'HR workbench removes previous identity claims and badge before the next list arrives',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _Repository();
      final identity = StateProvider<String>((ref) => 'A');
      final container = ProviderContainer(
        overrides: [
          hrTaskRepositoryProvider.overrideWithValue(repository),
          masterDataSessionKeyProvider.overrideWith(
            (ref) => ref.watch(identity),
          ),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'A'),
          ),
          currentPermissionsProvider.overrideWithValue({
            Perm.employeeView,
            Perm.employeePiiEdit,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiBaseUrlProvider.overrideWithValue('http://hr-test.invalid/api'),
          fixedBadgeSummaryOverride(),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const HrWorkbenchPage()),
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
      repository.requests[0].complete(_summary('旧身份独有员工', count: 2));
      await tester.pumpAndSettle();
      final countKey = find.byKey(
        const ValueKey('hr-workbench-entry-count-identity'),
      );
      expect(tester.widget<UtenNotificationBadge>(countKey).count, 2);
      expect(find.textContaining('旧身份独有员工'), findsWidgets);
      container.read(identity.notifier).state = 'B';
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('旧身份独有员工'), findsNothing);
      expect(countKey, findsNothing);
      repository.requests[1].complete(_summary('新身份员工'));
      await tester.pumpAndSettle();
      expect(find.textContaining('新身份员工'), findsWidgets);
      expect(tester.widget<UtenNotificationBadge>(countKey).count, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final reportFailure in [false, true]) {
    test(
      'silent failure keeps accepted tasks and exposes retry feedback reportFailure=$reportFailure',
      () async {
        final repository = _Repository();
        final container = ProviderContainer(
          overrides: [
            hrTaskRepositoryProvider.overrideWithValue(repository),
            masterDataSessionKeyProvider.overrideWithValue('A'),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'A'),
            ),
            fixedBadgeSummaryOverride(),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(hrTaskSummaryProvider, (_, _) {});
        addTearDown(subscription.close);
        repository.requests[0].complete(_summary('accepted tasks'));
        await container.read(hrTaskSummaryProvider.future);
        final notifier = container.read(hrTaskSummaryProvider.notifier);
        final failing = notifier.reloadSilently(reportFailure: reportFailure);
        final failure = NetworkException('Summary unavailable');
        final observed = reportFailure
            ? expectLater(failing, throwsA(same(failure)))
            : expectLater(failing, completes);
        repository.requests[1].completeError(failure);
        await observed;
        expect(
          container.read(hrTaskSummaryProvider).requireValue.generatedAt,
          'accepted tasks',
        );
        expect(container.read(hrTaskSummaryProvider).hasError, isFalse);
        expect(container.read(hrTaskRefreshStatusProvider), (
          refreshing: false,
          error: 'Summary unavailable',
        ));

        final retry = notifier.reloadSilently(reportFailure: true);
        expect(container.read(hrTaskRefreshStatusProvider), (
          refreshing: true,
          error: null,
        ));
        repository.requests[2].complete(_summary('fresh tasks'));
        await retry;
        expect(
          container.read(hrTaskSummaryProvider).requireValue.generatedAt,
          'fresh tasks',
        );
        expect(container.read(hrTaskRefreshStatusProvider), (
          refreshing: false,
          error: null,
        ));
      },
    );
  }

  for (final workbench in [true, false]) {
    testWidgets(
      '${workbench ? 'HR workbench' : 'HR task list'} return revalidates without removing accepted tasks and labels failed updates',
      (tester) async {
        RouteTransitionTracker.instance.reset();
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final repository = _Repository();
        final container = ProviderContainer(
          overrides: [
            hrTaskRepositoryProvider.overrideWithValue(repository),
            masterDataSessionKeyProvider.overrideWithValue('A'),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'A'),
            ),
            currentPermissionsProvider.overrideWithValue({
              Perm.employeeView,
              Perm.employeePiiEdit,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            sharedPreferencesProvider.overrideWithValue(preferences),
            apiBaseUrlProvider.overrideWithValue('https://hr-test.invalid/api'),
            formDraftStorageProvider.overrideWithValue(MemoryCasStorage()),
            fixedBadgeSummaryOverride(),
          ],
        );
        addTearDown(container.dispose);
        final location = workbench
            ? RouteName.hrTaskCenter
            : RouteName.hrTaskList('identity');
        final router = GoRouter(
          initialLocation: location,
          routes: [
            GoRoute(
              path: location,
              builder: (_, _) => workbench
                  ? const HrWorkbenchPage()
                  : const HrTaskListPage(type: HrTaskType.identity),
            ),
            GoRoute(
              path: '/child',
              builder: (_, _) => const Scaffold(body: Text('Child page')),
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
        repository.requests[0].complete(_summary('Accepted employee'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Accepted employee'), findsWidgets);
        final feedback = tester.element(find.byType(HrTaskRefreshFeedback));
        router.push<void>('/child');
        await tester.pumpAndSettle();
        router.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(repository.requests, hasLength(2));
        expect(find.textContaining('Accepted employee'), findsWidgets);
        expect(
          tester.element(find.byType(HrTaskRefreshFeedback)),
          same(feedback),
        );
        repository.requests[1].completeError(
          NetworkException('Summary unavailable'),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Accepted employee'), findsWidgets);
        expect(find.text('更新失败，当前显示上次内容'), findsOneWidget);
        expect(find.text('Summary unavailable'), findsOneWidget);
        await tester.tap(find.text('重新更新'));
        await tester.pump();
        expect(repository.requests, hasLength(3));
        expect(find.textContaining('Accepted employee'), findsWidgets);
        repository.requests[2].complete(_summary('Current employee'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Current employee'), findsWidgets);
        expect(find.textContaining('Accepted employee'), findsNothing);
        expect(find.text('更新失败，当前显示上次内容'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
