import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/models/audit_session.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_session_detail_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    '375px deep page loads authoritative summary and detailed Beijing timeline',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _FakeAuditLogRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              auditLogRepositoryProvider.overrideWithValue(repository),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: const MaterialApp(
              home: AdminAuditSessionDetailPage(
                sessionId: sessionId,
                routeSnapshotAuditId: 9001,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(repository.summaryCalls, 1);
        expect(repository.eventSnapshots, [9001]);
        expect(find.text('一次登录，一条完整时间线'), findsOneWidget);
        expect(find.textContaining('最新操作在前'), findsOneWidget);
        expect(find.text('查看销售订单历史单据'), findsOneWidget);
        expect(find.text('查看了销售订单历史单据：SO-2026-001(旧系统编号 86)'), findsOneWidget);
        expect(find.textContaining('业务对象 销售订单'), findsOneWidget);
        expect(find.textContaining('对象名称 销售订货单'), findsOneWidget);
        expect(find.textContaining('业务编号 SO-2026-001'), findsOneWidget);
        expect(
          find.text(
            '业务对象 销售订单 · 对象名称 销售订货单 · '
            '业务编号 SO-2026-001 · 旧系统编号 86',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('2026-08-30 00:00(北京时间)'), findsOneWidget);
        expect(find.text('其他业务对象'), findsNothing);
        expect(
          find.bySemanticsLabel(RegExp(r'具体操作 查看销售订单历史单据.*结果 成功')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        final eventFinder = find.byKey(
          const ValueKey('audit-session-event-42'),
        );
        await tester.ensureVisible(eventFinder);
        await tester.tap(eventFinder);
        await tester.pumpAndSettle();

        expect(repository.detailCalls, [42]);
        expect(find.text('这次操作做了什么'), findsOneWidget);
        expect(find.text('概览'), findsOneWidget);
        expect(find.text('数据变更'), findsOneWidget);
        expect(find.text('设备证据'), findsOneWidget);
        expect(find.text('排查信息'), findsOneWidget);
        expect(find.text('查看了销售订单历史单据：SO-2026-001(旧系统编号 86)'), findsWidgets);
        expect(
          find.text('销售订单 · 销售订货单 · 业务编号 SO-2026-001 · 旧系统编号 86'),
          findsOneWidget,
        );
        expect(find.text('王小明(sales01)'), findsWidgets);
        expect(find.text('2026-08-30 00:00(北京时间)'), findsWidgets);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('summary failure provides page-level retry', (tester) async {
    final repository = _FakeAuditLogRepository(failFirstSummary: true);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          auditLogRepositoryProvider.overrideWithValue(repository),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          home: AdminAuditSessionDetailPage(sessionId: sessionId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('会话摘要加载失败'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('audit-session-retry')));
    await tester.pumpAndSettle();
    expect(repository.summaryCalls, 2);
    expect(find.text('人员操作时间线'), findsOneWidget);
  });

  testWidgets(
    'dark mode with large text keeps summary and timeline controls usable',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            auditLogRepositoryProvider.overrideWithValue(
              _FakeAuditLogRepository(),
            ),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: MaterialApp(
            theme: ThemeData(colorSchemeSeed: Colors.teal),
            darkTheme: ThemeData(
              brightness: Brightness.dark,
              colorSchemeSeed: Colors.teal,
            ),
            themeMode: ThemeMode.dark,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const AdminAuditSessionDetailPage(
              sessionId: sessionId,
              routeSnapshotAuditId: 9001,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        Theme.of(
          tester.element(
            find.byKey(const ValueKey('audit-session-detail-refresh')),
          ),
        ).brightness,
        Brightness.dark,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('audit-session-detail-refresh')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(find.text('一次登录，一条完整时间线'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _FakeAuditLogRepository implements AuditLogRepository {
  _FakeAuditLogRepository({this.failFirstSummary = false});

  final bool failFirstSummary;
  int summaryCalls = 0;
  final List<int?> eventSnapshots = [];
  final List<int> detailCalls = [];

  @override
  Future<AuditSessionSummary> sessionSummary({
    required String sessionId,
    int? snapshotAuditId,
  }) async {
    summaryCalls++;
    if (failFirstSummary && summaryCalls == 1) {
      throw Exception('temporary');
    }
    return sessionFixture;
  }

  @override
  Future<AuditSessionEventPage> sessionEvents({
    required String sessionId,
    int size = 20,
    String? cursorAt,
    int? cursorId,
    int? snapshotAuditId,
  }) async {
    eventSnapshots.add(snapshotAuditId);
    return const AuditSessionEventPage(
      items: [eventFixture],
      hasMore: false,
      snapshotAuditId: 9001,
    );
  }

  @override
  Future<AuditLogDetail> detail(int id) async {
    detailCalls.add(id);
    return detailFixture;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const sessionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

const sessionFixture = AuditSessionSummary(
  sessionId: sessionId,
  actorId: '123e4567-e89b-42d3-a456-426614174099',
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  actorDepartment: '销售部',
  actorPosition: '销售专员',
  startAction: 'login',
  startLabel: '员工登录',
  loginAt: '2026-08-29T15:30:00Z',
  lastActivityAt: '2026-08-29T16:00:00Z',
  logoutAt: '2026-08-29T16:30:00Z',
  status: 'normal_logout',
  statusLabel: '正常退出',
  operationCount: 1,
  eventCount: 3,
  successCount: 3,
  deviceLabel: '销售部电脑',
  devicePlatform: 'Windows',
  snapshotAuditId: 9001,
);

const eventFixture = AuditLogEntry(
  id: 42,
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  action: 'view_sales_order_detail_history',
  actionLabel: '查看销售订单历史单据',
  objectLabel: '销售订单',
  targetId: '11111111-1111-4111-8111-111111111111',
  targetName: 'SO-2026-001(旧系统编号 86)',
  targetDisplayName: '销售订货单',
  targetBusinessCode: 'SO-2026-001',
  targetLegacyCode: '86',
  pageLabel: '销售历史单据',
  summary: '查看销售订单历史单据 SO-2026-001(旧系统编号 86)',
  result: 'success',
  resultLabel: '成功',
  createdAt: '2026-08-29T16:00:00Z',
);

const detailFixture = AuditLogDetail(
  id: 42,
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  actorDepartment: '销售部',
  actorPosition: '销售专员',
  action: 'view_sales_order_detail_history',
  actionLabel: '查看销售订单历史单据',
  objectLabel: '销售订单',
  targetId: '11111111-1111-4111-8111-111111111111',
  targetName: 'SO-2026-001(旧系统编号 86)',
  targetDisplayName: '销售订货单',
  targetBusinessCode: 'SO-2026-001',
  targetLegacyCode: '86',
  pageLabel: '销售历史单据',
  summary: '王小明查看销售订单历史单据 SO-2026-001(旧系统编号 86)',
  ip: '192.0.2.10',
  result: 'success',
  resultLabel: '成功',
  httpMethod: 'GET',
  statusCode: 200,
  durationMs: 18,
  requestId: '123e4567-e89b-42d3-a456-426614174000',
  createdAt: '2026-08-29T16:00:00Z',
);
