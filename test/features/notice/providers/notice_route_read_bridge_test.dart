import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/providers/notice_route_read_bridge.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';

/// 通知目标路由桥契约：
/// - recordRoutes 归一（去 query、忽略空/根路径）、consume 移除；
/// - 通知列表加载把「未读」通知的 action_route 留档；
/// - 路由落点命中留档集合 → 触发 read-by-route 已读并消费该路由。
class _FakeNoticeRepository implements NoticeRepository {
  final List<List<String>> routeCalls = [];
  List<Notice> listResult = const [];

  @override
  Future<List<Notice>> list({bool? onlyUnread}) async => listResult;

  @override
  Future<int> markReadByRoute(List<String> routes) async {
    routeCalls.add(routes);
    return routes.length;
  }

  @override
  Future<int> unreadCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Notice _noticeWith(String id, {bool isRead = false, String? actionRoute}) {
  return Notice(
    id: id,
    title: '通知 $id',
    content: '正文 $id',
    type: NoticeType.task,
    publisher: '系统',
    publishedAt: DateTime.utc(2026, 9, 2, 1),
    isRead: isRead,
    actionRoute: actionRoute,
  );
}

void main() {
  test('recordRoutes normalizes paths and consume removes them', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(noticeTargetRoutesProvider.notifier);

    notifier.recordRoutes([
      '/finance/procurement-approvals?returnTo=/notice',
      null,
      '',
      '/',
      '/finance/payables',
    ]);
    expect(container.read(noticeTargetRoutesProvider), {
      '/finance/procurement-approvals',
      '/finance/payables',
    });

    notifier.consume('/finance/payables');
    expect(container.read(noticeTargetRoutesProvider), {
      '/finance/procurement-approvals',
    });
    notifier.consume('/finance/payables'); // 未在集合中：no-op
    expect(container.read(noticeTargetRoutesProvider), hasLength(1));
  });

  test(
    'notice list build records action routes of unread notices only',
    () async {
      final repo = _FakeNoticeRepository()
        ..listResult = [
          _noticeWith('a', actionRoute: '/finance/payables'),
          _noticeWith(
            'b',
            isRead: true,
            actionRoute: '/finance/procurement-approvals',
          ),
          _noticeWith('c'),
        ];
      final container = ProviderContainer(
        overrides: [noticeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await container.read(noticeListProvider.future);

      expect(container.read(noticeTargetRoutesProvider), {'/finance/payables'});
    },
  );

  testWidgets('landing on a recorded route triggers read-by-route once', (
    tester,
  ) async {
    final repo = _FakeNoticeRepository()
      ..listResult = [
        _noticeWith(
          'a',
          actionRoute: '/finance/procurement-approvals',
        ),
      ];
    final container = ProviderContainer(
      overrides: [noticeRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: NoticeRouteReadBridge()),
      ),
    );
    await container.read(noticeListProvider.future);
    await tester.pump();

    // 未落定到目标路由：不触发。
    expect(repo.routeCalls, isEmpty);

    void landOn(String location) {
      final cur = container.read(pageResumeProvider);
      container.read(pageResumeProvider.notifier).state = (
        location: location,
        tick: cur.tick + 1,
      );
    }

    landOn('/dashboard');
    await tester.pump();
    expect(repo.routeCalls, isEmpty); // 未命中留档集合

    landOn('/finance/procurement-approvals');
    await tester.pump();
    expect(repo.routeCalls, [
      ['/finance/procurement-approvals'],
    ]);
    // 已消费：同一落点再触发也不重复调用。
    landOn('/dashboard');
    landOn('/finance/procurement-approvals');
    await tester.pump();
    expect(repo.routeCalls, hasLength(1));
    expect(container.read(noticeTargetRoutesProvider), isEmpty);

    // helper 会实例化未读数 provider（60s 轮询定时器）：先拆树再释放容器，
    // 避免 testWidgets 收尾时悬挂定时器断言。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  });
}
