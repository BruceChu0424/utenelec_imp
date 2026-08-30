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
    '375px card is collapsed, semantic and keeps a cross-midnight session whole',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var loads = 0;

        await _pumpCard(
          tester,
          loadEvents:
              ({String? cursorAt, int? cursorId, int? snapshotAuditId}) async {
                loads++;
                return const AuditSessionEventPage(
                  items: [],
                  hasMore: false,
                  snapshotAuditId: 9001,
                );
              },
        );

        expect(loads, 0);
        expect(
          find.textContaining('员工登录 2026-08-29 23:30(北京时间)'),
          findsOneWidget,
        );
        expect(find.textContaining('2026-08-30 01:30(北京时间)'), findsOneWidget);
        expect(find.text('已退出'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('audit-session-event-42')),
          findsNothing,
        );
        expect(find.bySemanticsLabel(RegExp(r'用户会话.*已折叠')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('expansion lazily loads, keyset appends and event taps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <(String?, int?, int?)>[];
    AuditLogEntry? opened;
    await _pumpCard(
      tester,
      onOpenEvent: (entry) => opened = entry,
      loadEvents:
          ({String? cursorAt, int? cursorId, int? snapshotAuditId}) async {
            calls.add((cursorAt, cursorId, snapshotAuditId));
            if (cursorId == null) {
              return const AuditSessionEventPage(
                items: [_firstEvent],
                nextCursorAt: '2026-08-29T16:00:00Z',
                nextCursorId: 42,
                hasMore: true,
                snapshotAuditId: 9001,
              );
            }
            return const AuditSessionEventPage(
              items: [_secondEvent],
              hasMore: false,
              snapshotAuditId: 9001,
            );
          },
    );

    expect(calls, isEmpty);
    await tester.tap(
      find.byKey(ValueKey('audit-session-${_session.sessionId}')),
    );
    await tester.pumpAndSettle();
    expect(calls, [(null, null, 9001)]);
    expect(
      find.byKey(const ValueKey('audit-session-event-42')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(
            find.byKey(
              ValueKey('audit-session-load-more-${_session.sessionId}'),
            ),
          )
          .width,
      greaterThan(250),
    );

    await tester.tap(
      find.byKey(ValueKey('audit-session-load-more-${_session.sessionId}')),
    );
    await tester.pumpAndSettle();
    expect(calls, [(null, null, 9001), ('2026-08-29T16:00:00Z', 42, 9001)]);
    expect(
      find.byKey(const ValueKey('audit-session-event-42')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('audit-session-event-41')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('audit-session-event-41')));
    expect(opened?.id, 41);
  });

  testWidgets('one-card event error retries without reloading sessions', (
    tester,
  ) async {
    var calls = 0;
    await _pumpCard(
      tester,
      loadEvents:
          ({String? cursorAt, int? cursorId, int? snapshotAuditId}) async {
            calls++;
            if (calls == 1) throw Exception('temporary');
            return const AuditSessionEventPage(
              items: [_firstEvent],
              hasMore: false,
              snapshotAuditId: 9001,
            );
          },
    );

    await tester.tap(
      find.byKey(ValueKey('audit-session-${_session.sessionId}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('会话时间线加载失败'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('audit-session-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(
      find.byKey(const ValueKey('audit-session-event-42')),
      findsOneWidget,
    );
  });

  testWidgets('server session status codes have readable icon fallbacks', (
    tester,
  ) async {
    for (final testCase in const [
      ('normal_logout', '正常退出', Icons.logout_rounded),
      ('no_logout_record', '结束状态待核查', Icons.help_outline_rounded),
      ('security_terminated', '安全中断', Icons.warning_amber_rounded),
      ('activity_after_logout', '退出后仍有操作', Icons.warning_amber_rounded),
    ]) {
      await _pumpCard(
        tester,
        session: _sessionForStatus(testCase.$1),
        loadEvents:
            ({String? cursorAt, int? cursorId, int? snapshotAuditId}) async =>
                const AuditSessionEventPage(
                  items: [],
                  hasMore: false,
                  snapshotAuditId: 9001,
                ),
      );
      expect(find.text(testCase.$2), findsOneWidget);
      expect(find.byIcon(testCase.$3), findsOneWidget);
    }
  });
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required AuditSessionEventLoader loadEvents,
  ValueChanged<AuditLogEntry>? onOpenEvent,
  AuditSessionSummary session = _session,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              AuditSessionCard(
                session: session,
                snapshotAuditId: 9001,
                loadEvents: loadEvents,
                onOpenEvent: onOpenEvent ?? (_) {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

AuditSessionSummary _sessionForStatus(String status) => AuditSessionSummary(
  sessionId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  startAction: 'login',
  startLabel: '员工登录',
  loginAt: '2026-08-29T15:30:00Z',
  lastActivityAt: '2026-08-29T17:20:00Z',
  status: status,
  operationCount: 2,
  eventCount: 2,
  successCount: 2,
);

const _session = AuditSessionSummary(
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
);

const _firstEvent = AuditLogEntry(
  id: 42,
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  action: 'view_sales_order_detail',
  actionLabel: '查看销售订单详情',
  targetName: 'SO-001',
  summary: '查看销售订单详情 SO-001',
  result: 'success',
  resultLabel: '成功',
  createdAt: '2026-08-29T16:00:00Z',
);

const _secondEvent = AuditLogEntry(
  id: 41,
  actorAccount: 'sales01',
  actorDisplay: '王小明(sales01)',
  action: 'update',
  actionLabel: '修改',
  targetName: 'SO-002',
  summary: '修改销售订单 SO-002',
  result: 'success',
  resultLabel: '成功',
  createdAt: '2026-08-29T15:50:00Z',
);
