import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/models/audit_session.dart';
import 'package:uten_imp/features/admin/widgets/audit_session_card.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets(
    '375px session card is a semantic route entry, not inline detail',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var opened = 0;
      try {
        await tester.pumpWidget(
          await _withPreferences(
            MaterialApp(
              home: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    AuditSessionCard(
                      session: sessionFixture,
                      onOpen: () => opened++,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        expect(find.text('查看会话时间线'), findsOneWidget);
        expect(find.textContaining('2026-08-29 23:30(北京时间)'), findsOneWidget);
        expect(find.textContaining('2026-08-30 01:30(北京时间)'), findsOneWidget);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(
          find.byKey(const ValueKey('audit-session-event-42')),
          findsNothing,
        );
        expect(
          find.bySemanticsLabel(RegExp(r'登录会话.*点击进入会话时间线')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(ValueKey('audit-session-${sessionFixture.sessionId}')),
        );
        expect(opened, 1);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'timeline loads first page, appends composite cursor and opens event',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <(String?, int?, int?)>[];
      AuditLogEntry? opened;
      await _pumpTimeline(
        tester,
        onOpenEvent: (entry) => opened = entry,
        loader: ({cursorAt, cursorId, snapshotAuditId}) async {
          calls.add((cursorAt, cursorId, snapshotAuditId));
          if (cursorId == null) {
            return const AuditSessionEventPage(
              items: [firstEvent],
              nextCursorAt: '2026-08-29T16:00:00Z',
              nextCursorId: 42,
              hasMore: true,
              snapshotAuditId: 9001,
            );
          }
          return const AuditSessionEventPage(
            items: [secondEvent],
            hasMore: false,
            snapshotAuditId: 9001,
          );
        },
      );
      await tester.pumpAndSettle();

      expect(calls, [(null, null, 9001)]);
      expect(find.text('查看销售历史订单详情'), findsOneWidget);
      expect(find.textContaining('业务对象 销售历史订单'), findsOneWidget);
      expect(find.textContaining('名称或单据编号 SO-001'), findsOneWidget);
      expect(find.text('成功'), findsOneWidget);

      await tester.tap(
        find.byKey(
          ValueKey('audit-session-load-more-${sessionFixture.sessionId}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, [(null, null, 9001), ('2026-08-29T16:00:00Z', 42, 9001)]);
      expect(
        find.byKey(const ValueKey('audit-session-event-41')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('audit-session-event-41')));
      expect(opened?.id, 41);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'timeline load error has local retry and empty state is explicit',
    (tester) async {
      var calls = 0;
      await _pumpTimeline(
        tester,
        loader: ({cursorAt, cursorId, snapshotAuditId}) async {
          calls++;
          if (calls == 1) throw Exception('temporary');
          return const AuditSessionEventPage(
            items: [],
            hasMore: false,
            snapshotAuditId: 9001,
          );
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('会话时间线加载失败'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('audit-session-retry')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('该会话暂无可展示的人工操作'), findsOneWidget);
    },
  );

  testWidgets('server status values always have readable Chinese labels', (
    tester,
  ) async {
    for (final testCase in const [
      ('normal_logout', '正常退出', Icons.logout_rounded),
      ('no_logout_record', '结束状态待核查', Icons.help_outline_rounded),
      ('security_terminated', '安全中断', Icons.warning_amber_rounded),
      ('activity_after_logout', '退出后仍有操作', Icons.warning_amber_rounded),
    ]) {
      await tester.pumpWidget(
        await _withPreferences(
          MaterialApp(
            home: Scaffold(
              body: AuditSessionCard(
                session: sessionFixture.copyForStatus(testCase.$1),
                onOpen: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text(testCase.$2), findsOneWidget);
      expect(find.byIcon(testCase.$3), findsOneWidget);
    }
  });
}

Future<void> _pumpTimeline(
  WidgetTester tester, {
  required AuditSessionEventLoader loader,
  ValueChanged<AuditLogEntry>? onOpenEvent,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: AuditSessionTimeline(
          sessionId: sessionFixture.sessionId,
          snapshotAuditId: 9001,
          loadEvents: loader,
          onOpenEvent: onOpenEvent ?? (_) {},
        ),
      ),
    ),
  ),
);

Future<Widget> _withPreferences(Widget child) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    child: child,
  );
}

extension on AuditSessionSummary {
  AuditSessionSummary copyForStatus(String nextStatus) => AuditSessionSummary(
    sessionId: sessionId,
    actorAccount: actorAccount,
    actorDisplay: actorDisplay,
    startLabel: startLabel,
    loginAt: loginAt,
    lastActivityAt: lastActivityAt,
    status: nextStatus,
    operationCount: operationCount,
    eventCount: eventCount,
    successCount: successCount,
    snapshotAuditId: snapshotAuditId,
  );
}

const sessionFixture = AuditSessionSummary(
  sessionId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
  actorId: '123e4567-e89b-42d3-a456-426614174099',
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  actorDepartment: '销售部',
  actorPosition: '销售专员',
  startAction: 'login',
  startLabel: '员工登录',
  loginAt: '2026-08-29T15:30:00Z',
  firstActivityAt: '2026-08-29T15:31:00Z',
  lastActivityAt: '2026-08-29T17:20:00Z',
  logoutAt: '2026-08-29T17:30:00Z',
  status: 'logged_out',
  statusLabel: '已退出',
  operationCount: 2,
  eventCount: 3,
  successCount: 2,
  failureCount: 1,
  deviceLabel: '测试电脑',
  devicePlatform: 'Windows',
  snapshotAuditId: 9001,
);

const firstEvent = AuditLogEntry(
  id: 42,
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  action: 'view_sales_order_history_detail',
  actionLabel: '查看销售历史订单详情',
  objectLabel: '销售历史订单',
  targetId: '11111111-1111-4111-8111-111111111111',
  targetName: 'SO-001',
  pageLabel: '销售历史单据',
  summary: '查看销售历史订单 SO-001',
  result: 'success',
  resultLabel: '成功',
  createdAt: '2026-08-29T16:00:00Z',
);

const secondEvent = AuditLogEntry(
  id: 41,
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  action: 'update_sales_order',
  actionLabel: '修改销售订单',
  objectLabel: '销售订单',
  targetId: '22222222-2222-4222-8222-222222222222',
  targetName: 'SO-002',
  pageLabel: '销售订单',
  summary: '修改销售订单 SO-002',
  result: 'success',
  resultLabel: '成功',
  createdAt: '2026-08-29T15:50:00Z',
);
