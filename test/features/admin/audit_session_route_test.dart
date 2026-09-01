import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/models/audit_session.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_session_detail_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'audit session route encodes id, carries snapshot and keeps audit view',
    () {
      final path = RoutePath.adminAuditSession(
        'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        snapshotAuditId: 9001,
      );

      expect(
        path,
        '/admin/audit-logs/sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        '?snapshotAuditId=9001',
      );
      expect(requiredAnyPermFor(path), const [Perm.auditLogView]);
      expect(
        requiredAnyPermFor(
          '/admin/audit-logs/sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        ),
        const [Perm.auditLogView],
      );
      final investigation = RoutePath.adminAuditInvestigation(
        '123e4567-e89b-42d3-a456-426614174000',
      );
      expect(
        investigation,
        '/admin/audit-logs'
        '?requestId=123e4567-e89b-42d3-a456-426614174000',
      );
      expect(requiredAnyPermFor(investigation), const [Perm.auditLogView]);
    },
  );

  testWidgets(
    'real router push preserves source state and deep-link back has a fallback',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _RouteAuditRepository();
      late final GoRouter router;
      router = GoRouter(
        initialLocation: RouteName.adminAuditLogs,
        routes: [
          GoRoute(
            path: RouteName.adminAuditLogs,
            builder: (_, _) => _AuditRouteSource(
              onOpen: () => router.push(
                RoutePath.adminAuditSession(
                  _routeSession.sessionId,
                  snapshotAuditId: _routeSession.snapshotAuditId,
                ),
                extra: _routeSession,
              ),
            ),
            routes: [
              GoRoute(
                path: 'sessions/:sessionId',
                builder: (_, state) => AdminAuditSessionDetailPage(
                  sessionId: state.pathParameters['sessionId'] ?? '',
                  routeSnapshotAuditId: int.tryParse(
                    state.uri.queryParameters['snapshotAuditId'] ?? '',
                  ),
                  initialSummary: state.extra is AuditSessionSummary
                      ? state.extra! as AuditSessionSummary
                      : null,
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            auditLogRepositoryProvider.overrideWithValue(repository),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('改变调查状态'));
      await tester.pump();
      expect(find.text('调查状态 1'), findsOneWidget);
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '打开会话'))
          .onPressed!();
      await tester.pumpAndSettle();

      expect(find.text('会话时间线'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(find.text('调查状态 1'), findsOneWidget);

      router.go(
        '/admin/audit-logs/sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      );
      await tester.pumpAndSettle();
      expect(find.text('会话时间线'), findsOneWidget);
      expect(repository.summaryCalls, greaterThanOrEqualTo(2));
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        RouteName.adminAuditLogs,
      );
    },
  );
}

class _AuditRouteSource extends StatefulWidget {
  const _AuditRouteSource({required this.onOpen});

  final VoidCallback onOpen;

  @override
  State<_AuditRouteSource> createState() => _AuditRouteSourceState();
}

class _AuditRouteSourceState extends State<_AuditRouteSource> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text('调查状态 $count'),
          FilledButton(
            onPressed: () => setState(() => count++),
            child: const Text('改变调查状态'),
          ),
          FilledButton(onPressed: widget.onOpen, child: const Text('打开会话')),
        ],
      ),
    );
  }
}

class _RouteAuditRepository implements AuditLogRepository {
  int summaryCalls = 0;

  @override
  Future<AuditSessionSummary> sessionSummary({
    required String sessionId,
    int? snapshotAuditId,
  }) async {
    summaryCalls++;
    return _routeSession;
  }

  @override
  Future<AuditSessionEventPage> sessionEvents({
    required String sessionId,
    int size = 20,
    String? cursorAt,
    int? cursorId,
    int? snapshotAuditId,
  }) async => const AuditSessionEventPage(
    items: <AuditLogEntry>[],
    hasMore: false,
    snapshotAuditId: 9001,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _routeSession = AuditSessionSummary(
  sessionId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
  actorAccount: 'sales01',
  actorDisplay: '王小明（sales01）',
  startLabel: '员工登录',
  loginAt: '2026-08-30T08:00:00+08:00',
  lastActivityAt: '2026-08-30T09:00:00+08:00',
  status: 'normal_logout',
  statusLabel: '正常退出',
  eventCount: 3,
  operationCount: 1,
  successCount: 3,
  snapshotAuditId: 9001,
);
