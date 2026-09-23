import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/providers/notice_unread_index_provider.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';

import '../../../helpers/badge_summary_fixture.dart';

/// markNoticesReadByRoute 的 provider 级契约：
/// - 正常路径调用 read-by-route 并使列表失效、徽章汇总(含未读数)立即重拉；
/// - 本地未读索引里没有指向这些页面的未读时不发请求(ADR-108, 此前每次导航都空写一次)；
/// - 仓储抛错静默放行（业务保存流不被打断）；
/// - 空路由直接短路，不触网络。
class _FakeNoticeRepository implements NoticeRepository {
  _FakeNoticeRepository({this.failRouteRead = false});

  final bool failRouteRead;
  final List<List<String>> routeCalls = [];
  int listCalls = 0;

  @override
  Future<int> markReadByRoute(List<String> routes) async {
    routeCalls.add(routes);
    if (failRouteRead) throw StateError('network down');
    return routes.length;
  }

  @override
  Future<List<Notice>> list({bool? onlyUnread}) async {
    listCalls++;
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'marks notices read by route, invalidates list and refreshes badge',
    () async {
      final repo = _FakeNoticeRepository();
      final badges = FixedBadgeSummaryNotifier(badgeSummaryFixture());
      final container = ProviderContainer(
        overrides: [
          noticeRepositoryProvider.overrideWithValue(repo),
          badgeSummaryProvider.overrideWith(() => badges),
        ],
      );
      addTearDown(container.dispose);

      // 挂监听让列表失效真实触发重建（无监听的 invalidate 不会重新执行）。
      final sub = container.listen(noticeListProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(noticeListProvider.future); // 等初始异步 build 完成
      final listCallsAfterListen = repo.listCalls;
      expect(listCallsAfterListen, 1);

      await markNoticesReadByRoute(container, [
        '/purchase/orders/x',
        '/subcontract/orders/y',
      ]);
      await container.read(noticeListProvider.future); // 等失效后的异步重建完成

      expect(repo.routeCalls, [
        ['/purchase/orders/x', '/subcontract/orders/y'],
      ]);
      // 列表失效重建一次; 徽章汇总(含未读数)立即重拉一次。
      expect(repo.listCalls, listCallsAfterListen + 1);
      expect(badges.refreshCalls, 1);
    },
  );

  test(
    'repository failure is swallowed so business flows are not interrupted',
    () async {
      final repo = _FakeNoticeRepository(failRouteRead: true);
      final container = ProviderContainer(
        overrides: [noticeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      await markNoticesReadByRoute(container, [
        '/warehouse/inbound/expectations',
      ]);

      expect(repo.routeCalls, hasLength(1));
      // 失败路径不触发列表失效重建（未读数随后台轮询自然对齐）。
      expect(repo.listCalls, 0);
    },
  );

  test('empty route list is a no-op', () async {
    final repo = _FakeNoticeRepository();
    final container = ProviderContainer(
      overrides: [noticeRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);

    await markNoticesReadByRoute(container, const []);

    expect(repo.routeCalls, isEmpty);
    expect(repo.listCalls, 0);
  });

  test(
    'index knows no unread for these pages: 20 navigations, 0 requests',
    () async {
      final repo = _FakeNoticeRepository();
      final container = ProviderContainer(
        overrides: [
          noticeRepositoryProvider.overrideWithValue(repo),
          noticeUnreadIndexProvider.overrideWith(_KnownIndex.new),
        ],
      );
      addTearDown(container.dispose);

      for (var i = 0; i < 20; i++) {
        await markNoticesReadByRoute(container, ['/some/page/$i']);
      }
      expect(repo.routeCalls, isEmpty);

      // 真有指向该页的未读时照常发一次。
      await markNoticesReadByRoute(container, ['/purchase/orders/x']);
      expect(repo.routeCalls, [
        ['/purchase/orders/x'],
      ]);
    },
  );
}

/// 已拉到的未读索引: 只有一条指向采购订单 x 的未读。
class _KnownIndex extends NoticeUnreadIndexNotifier {
  @override
  NoticeUnreadIndex? build() => NoticeUnreadIndex(
    unreadCount: 1,
    digest: 1,
    items: [
      NoticeUnreadItem(
        id: 'n-1',
        publishedAt: DateTime.utc(2026, 9, 23),
        actionRoute: '/purchase/orders/x',
      ),
    ],
  );
}
