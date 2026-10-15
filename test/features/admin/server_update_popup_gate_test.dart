import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/ui/opportunistic_dialog_coordinator.dart';
import 'package:uten_imp/features/admin/models/server_operations.dart';
import 'package:uten_imp/features/admin/providers/server_operations_access.dart';
import 'package:uten_imp/features/admin/providers/server_storage_request_store.dart';
import 'package:uten_imp/features/admin/repositories/server_operations_repository.dart';
import 'package:uten_imp/features/admin/widgets/server_update_popup_gate.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/app_visibility_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/audit_screenshot_support.dart';

void main() {
  testWidgets('normal release reminder demonstration render', (tester) async {
    await loadAuditScreenshotFonts(tester);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await _pump(tester, _Repository(), capture: key);
    await _settleReminder(tester);
    expect(tester.takeException(), isNull);
    if (Platform.environment['UTEN_UI_FIXTURES'] == '1') {
      await saveAuditScreenshot(
        tester,
        key,
        'server-settings-normal-release-reminder-demo',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test(
    'priority interruption is replayed to a route that registers its listener later',
    () async {
      final coordinator = OpportunisticDialogCoordinator();
      final opportunity = coordinator.tryAcquire()!;
      final priority = coordinator.prioritize();
      var interrupted = 0;
      opportunity.addListener(() => interrupted++);
      await Future<void>.delayed(Duration.zero);
      expect(interrupted, 1);
      expect(opportunity.interrupted, true);
      expect(coordinator.tryAcquire(), isNull);
      priority.release();
      opportunity.dispose();
      coordinator.dispose();
    },
  );

  testWidgets(
    'a fresh local status reminder is normal, navigates explicitly, and deduplicates by revision/version',
    (tester) async {
      final repository = _Repository();
      final fixture = await _pump(tester, repository);
      await _settleReminder(tester);
      expect(find.text('服务器有新版本 v2.5.18'), findsOneWidget);
      expect(find.text('去更新'), findsOneWidget);
      expect(repository.statusCalls, 1);
      await tester.tap(find.text('去更新'));
      await tester.pumpAndSettle();
      expect(find.text('目标更新页'), findsOneWidget);
      fixture.router.go(RouteName.dashboard);
      await tester.pumpAndSettle();
      await _settleReminder(tester);
      expect(find.text('服务器有新版本 v2.5.18'), findsNothing);
      repository.version = 'v2.5.19';
      await tester.pump(const Duration(seconds: 60));
      await tester.pumpAndSettle();
      expect(find.text('服务器有新版本 v2.5.19'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'snooze does not clear badges and holds the same version for fifteen minutes',
    (tester) async {
      var now = DateTime.utc(2026, 10, 15);
      await withClock(Clock(() => now), () async {
        final repository = _Repository();
        final fixture = await _pump(tester, repository);
        await _settleReminder(tester);
        await tester.tap(find.text('稍后（15 分钟）'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 60));
        await tester.pumpAndSettle();
        expect(find.text('服务器有新版本 v2.5.18'), findsNothing);
        expect(
          fixture.container
              .read(badgeSummaryProvider)
              .entryTodo(BadgeEntry.serverUpdateAvailable),
          1,
        );
        now = now.add(const Duration(minutes: 16));
        await tester.pump(const Duration(seconds: 60));
        await tester.pumpAndSettle();
        expect(find.text('服务器有新版本 v2.5.18'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  testWidgets(
    'priority security dialog closes only this reminder and never consumes it',
    (tester) async {
      final repository = _Repository();
      final fixture = await _pump(tester, repository);
      await _settleReminder(tester);
      final context = tester.element(find.text('工作台内容'));
      final verification = showReauthDialog(
        context,
        verify: (_) async => 'not-a-real-token',
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReauthDialog), findsOneWidget);
      expect(find.text('服务器有新版本 v2.5.18'), findsNothing);
      expect(
        fixture.preferences.getKeys().where(
          (key) => key.startsWith('serverUpdate.reminder.'),
        ),
        isEmpty,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await verification;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('服务器有新版本 v2.5.18'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'existing review check blocks the low-priority popup before its own dialog opens',
    (tester) async {
      final repository = _Repository();
      final fixture = await _pump(tester, repository);
      final priority = fixture.container
          .read(opportunisticDialogCoordinatorProvider)
          .prioritize();
      await _settleReminder(tester);
      expect(repository.statusCalls, 0);
      priority.release();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('服务器有新版本 v2.5.18'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late status from a replaced owner cannot open or consume a reminder',
    (tester) async {
      final old = Completer<ServerOperationsStatus>();
      final repository = _Repository()..handler = () => old.future;
      final fixture = await _pump(tester, repository);
      await tester.pump(const Duration(seconds: 1));
      fixture.container.read(_owner.notifier).state = 'company-b/operator';
      repository.handler = () async => repository.sample(canUpdate: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      old.complete(repository.sample());
      await tester.pumpAndSettle();
      expect(find.text('服务器有新版本 v2.5.18'), findsNothing);
      expect(
        fixture.preferences.getKeys().where(
          (key) => key.startsWith('serverUpdate.reminder.'),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background, wrong route, unavailable host and unauthorized staff never prompt',
    (tester) async {
      final repository = _Repository();
      final fixture = await _pump(tester, repository, eligible: false);
      await _settleReminder(tester);
      expect(repository.statusCalls, 0);
      fixture.container.read(_eligible.notifier).state = true;
      fixture.container.read(appVisibilityProvider.notifier).debugSet(false);
      await tester.pump();
      await _settleReminder(tester);
      expect(repository.statusCalls, 0);
      fixture.container.read(appVisibilityProvider.notifier).debugSet(true);
      repository.handler = () async => repository.sample(available: false);
      await tester.pump();
      await _settleReminder(tester);
      expect(find.text('服务器有新版本 v2.5.18'), findsNothing);
      fixture.router.go('/business');
      await tester.pumpAndSettle();
      final before = repository.statusCalls;
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(repository.statusCalls, before);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

final _owner = StateProvider<Object?>((ref) => 'company-a/operator');
final _eligible = StateProvider((ref) => true);
Future<void> _settleReminder(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

Future<
  ({
    ProviderContainer container,
    SharedPreferences preferences,
    GoRouter router,
  })
>
_pump(
  WidgetTester tester,
  _Repository repository, {
  bool eligible = true,
  GlobalKey? capture,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: RouteName.dashboard,
    routes: [
      GoRoute(
        path: RouteName.dashboard,
        builder: (_, _) => const Scaffold(
          body: ServerUpdatePopupGate(visible: true, child: Text('工作台内容')),
        ),
      ),
      GoRoute(
        path: '/business',
        builder: (_, _) => const Scaffold(
          body: ServerUpdatePopupGate(visible: false, child: Text('业务页面')),
        ),
      ),
      GoRoute(
        path: RouteName.adminServerOperations,
        builder: (_, _) => const Scaffold(body: Text('目标更新页')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        _eligible.overrideWith((ref) => eligible),
        serverOperationsOwnerProvider.overrideWith((ref) => ref.watch(_owner)),
        serverStorageRequestOwnerProvider.overrideWith(
          (ref) => ref.watch(_owner)?.toString(),
        ),
        serverUpdateReminderEligibleProvider.overrideWith(
          (ref) => ref.watch(_eligible),
        ),
        serverOperationsRepositoryProvider.overrideWithValue(repository),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            entries: {BadgeEntry.serverUpdateAvailable: (1, 0)},
          ),
        ),
      ],
      child: MaterialApp.router(
        theme: auditScreenshotTheme(buildLightTheme()),
        builder: capture == null
            ? null
            : (context, child) => RepaintBoundary(key: capture, child: child!),
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
  return (container: container, preferences: preferences, router: router);
}

class _Repository implements ServerOperationsRepository {
  String version = 'v2.5.18';
  int statusCalls = 0;
  Future<ServerOperationsStatus> Function()? handler;
  ServerOperationsStatus sample({
    bool canUpdate = true,
    bool available = true,
  }) => ServerOperationsStatus.fromJson({
    'available': available,
    'canUpdate': canUpdate,
    'updateAvailable': true,
    'currentVersion': 'v2.5.17',
    'sourceRevision': 'r1',
    'latestVersion': version,
    'lastCheckedAt': '2026-10-15T12:00:00Z',
  });
  @override
  Future<ServerOperationsStatus> status() async {
    statusCalls++;
    return handler == null ? sample() : handler!();
  }

  @override
  Future<ServerUpdateJob> startUpdate({
    required String requestId,
    required String expectedSourceRevision,
    required String expectedCurrentVersion,
    String mode = 'CHECK_ONLY',
    String? targetVersion,
    String? scheduledAt,
  }) => throw StateError('reminder must never start updates');
  @override
  Future<ServerUpdateJob> cancel(String jobId, {required String requestId}) =>
      throw UnimplementedError();
  @override
  Future<ServerUpdateJob> job(String id) => throw UnimplementedError();
  @override
  Future<ServerUpdateJob?> latestJob() => throw UnimplementedError();
  @override
  Future<ServerUpdateSource> source() =>
      throw StateError('reminder must never read source credentials');
  @override
  Future<ServerUpdateSource> saveSource(Map<String, dynamic> command) =>
      throw UnimplementedError();
  @override
  Future<ServerUpdateSchedulePreview> schedulePreview({
    required String localDate,
    required int hour,
  }) => throw UnimplementedError();
}
