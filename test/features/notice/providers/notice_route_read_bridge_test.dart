import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/features/notice/providers/notice_page_clear_events.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/providers/notice_route_read_bridge.dart';
import 'package:uten_imp/features/notice/providers/notice_unread_index_provider.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

/// 通知落点已读桥契约（2026-09-18 无状态重写）：
/// - 任何路由落定都触发 read-by-route（action_route 精确清理），无需预登记；
/// - 落点命中 noticePageClearEvents 的页面（或其子路径）时，追加
///   read-by-source 清理该页承载的事件集；
/// - 事件集/路由清理只置已读，返回 0 条时不刷新角标（无轮询副作用）。
class _FakeNoticeRepository implements NoticeRepository {
  final routeCalls = <List<String>>[];
  final sourceCalls = <List<String>>[];

  @override
  Future<int> markReadByRoute(List<String> routes) async {
    routeCalls.add(routes);
    return 0; // 0 = 未实际置读，不触发未读角标刷新
  }

  @override
  Future<int> markReadBySource(List<String> events) async {
    sourceCalls.add(events);
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnknownIndex extends NoticeUnreadIndexNotifier {
  @override
  NoticeUnreadIndex? build() => null;
}

final _testScope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'staff-test'),
);

void main() {
  test('noticeClearEventsForLocation matches exact key and subpaths only', () {
    expect(noticeClearEventsForLocation('/warehouse/tasks/draw'), [
      'PRODUCTION_DRAW_PENDING',
    ]);
    expect(
      noticeClearEventsForLocation(
        '/finance/sales-order-confirmations/00000000-0000-0000-0000-000000000001',
      ),
      ['SALES_ORDER_PENDING_FINANCE_CONFIRM'],
    );
    // 未映射页面：无事件集（仍走精确路由清理）。
    expect(noticeClearEventsForLocation('/dashboard'), isEmpty);
    expect(noticeClearEventsForLocation('/home'), isEmpty);
    // 前缀相似但非子路径：material-analysis 与 material-analyses 互不误命中。
    expect(
      noticeClearEventsForLocation('/production/material-analyses/abc/summary'),
      contains('PROCUREMENT_IQC_RESOLVED'),
    );
    // ADR-143 委外领料页是任务中心子页：进领料页同样清掉可领料卡。
    expect(
      noticeClearEventsForLocation(
        '/operations/workbench/subcontract/draw-request',
      ),
      contains('SUBCONTRACT_DRAW_AVAILABLE'),
    );
    // ADR-156 可下单卡的 action_route 带 ?segment=pending&keyword=，进任务中心即清。
    expect(
      noticeClearEventsForLocation('/operations/workbench/subcontract'),
      contains('SUBCONTRACT_ORDER_KIT_READY'),
    );
    expect(
      noticeClearEventsForLocation('/warehouse/subcontract-outbound/issue-1'),
      ['SUBCONTRACT_OUTBOUND_READY', 'SUBCONTRACT_DRAW_WITHDRAWN'],
    );
    expect(
      noticeClearEventsForLocation('/production/material-analysis'),
      contains('SALES_ORDER_APPROVED'),
    );
  });

  testWidgets('landing fires read-by-route; mapped pages add read-by-source', (
    tester,
  ) async {
    final repo = _FakeNoticeRepository();
    final container = ProviderContainer(
      overrides: [
        noticeRepositoryProvider.overrideWithValue(repo),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_testScope)),
        noticeUnreadIndexProvider.overrideWith(_UnknownIndex.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: NoticeRouteReadBridge()),
      ),
    );
    await tester.pump();
    expect(repo.routeCalls, isEmpty); // 尚无落点变化

    void landOn(String location) {
      final cur = container.read(pageResumeProvider);
      container.read(pageResumeProvider.notifier).state = (
        location: location,
        tick: cur.tick + 1,
      );
    }

    // 普通页面：仅精确路由清理（无状态，无需任何预登记）。
    landOn('/dashboard');
    await tester.pump();
    expect(repo.routeCalls, [
      ['/dashboard'],
    ]);
    expect(repo.sourceCalls, isEmpty);

    // 队列页：精确路由清理 + 该页事件集清理。
    landOn('/warehouse/tasks/draw');
    await tester.pump();
    expect(repo.routeCalls.last, ['/warehouse/tasks/draw']);
    expect(repo.sourceCalls, [
      ['PRODUCTION_DRAW_PENDING'],
    ]);

    // 队列的详情子页：命中父队列事件集 + 自身精确路由清理。
    landOn(
      '/finance/sales-order-confirmations/00000000-0000-0000-0000-000000000001',
    );
    await tester.pump();
    expect(repo.routeCalls.last, [
      '/finance/sales-order-confirmations/00000000-0000-0000-0000-000000000001',
    ]);
    expect(repo.sourceCalls.last, ['SALES_ORDER_PENDING_FINANCE_CONFIRM']);

    // 未映射详情页（如订单详情）：仅精确路由清理——action_route 指向该页的
    // 通知由精确通道清理。
    landOn('/sales/orders/00000000-0000-0000-0000-000000000002');
    await tester.pump();
    expect(repo.routeCalls.last, [
      '/sales/orders/00000000-0000-0000-0000-000000000002',
    ]);
    expect(repo.sourceCalls, hasLength(2));

    // 运营任务工作台（采购/委外用户看「待分解」的实际入口页）。
    landOn('/operations/workbench/purchase');
    await tester.pump();
    expect(repo.routeCalls.last, ['/operations/workbench/purchase']);
    expect(repo.sourceCalls.last, contains('PREPLAN_SUPPLY_DOCUMENT_CREATED'));
  });

  testWidgets(
    'anonymous, password-gated and public routes never mark notices read',
    (tester) async {
      final repo = _FakeNoticeRepository();
      final container = ProviderContainer(
        overrides: [
          noticeRepositoryProvider.overrideWithValue(repo),
          authenticatedScopeProvider.overrideWith(
            (ref) => ref.watch(_testScope),
          ),
          noticeUnreadIndexProvider.overrideWith(_UnknownIndex.new),
        ],
      );
      addTearDown(container.dispose);
      container.read(_testScope.notifier).state = null;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: NoticeRouteReadBridge()),
        ),
      );
      void landOn(String location) {
        final current = container.read(pageResumeProvider);
        container.read(pageResumeProvider.notifier).state = (
          location: location,
          tick: current.tick + 1,
        );
      }

      // Reproduces cold startup /login and an expired session still on a queue.
      for (final route in [
        '/login',
        '/change-password',
        '/warehouse/tasks/draw',
      ]) {
        landOn(route);
        await tester.pump();
      }
      expect(repo.routeCalls, isEmpty);
      expect(repo.sourceCalls, isEmpty);
      container.read(_testScope.notifier).state = const AuthenticatedScope(
        userId: 'staff-test',
      );
      // Public/visitor pages do not consume staff notices even if staff is signed in.
      for (final route in [
        '/login',
        '/entry',
        '/change-password',
        '/visitor/home',
      ]) {
        landOn(route);
        await tester.pump();
      }
      expect(repo.routeCalls, isEmpty);
      expect(repo.sourceCalls, isEmpty);
      landOn('/warehouse/tasks/draw');
      await tester.pump();
      expect(repo.routeCalls, [
        ['/warehouse/tasks/draw'],
      ]);
      expect(repo.sourceCalls, [
        ['PRODUCTION_DRAW_PENDING'],
      ]);
      container.read(_testScope.notifier).state = null;
      landOn('/finance/sales-order-confirmations');
      await tester.pump();
      expect(repo.routeCalls, hasLength(1));
      expect(repo.sourceCalls, hasLength(1));
    },
  );
}
