import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';

/// markNoticesReadByRoute 的 provider 级契约：
/// - 正常路径调用 read-by-route 并使列表失效、未读数立即刷新；
/// - 仓储抛错静默放行（业务保存流不被打断）；
/// - 空路由直接短路，不触网络。
class _FakeNoticeRepository implements NoticeRepository {
  _FakeNoticeRepository({this.failRouteRead = false});

  final bool failRouteRead;
  final List<List<String>> routeCalls = [];
  int listCalls = 0;
  int unreadCountCalls = 0;

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
  Future<int> unreadCount() async {
    unreadCountCalls++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'marks notices read by route, invalidates list and refreshes badge',
    () async {
      final repo = _FakeNoticeRepository();
      final container = ProviderContainer(
        overrides: [noticeRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);

      // 挂监听让列表失效真实触发重建（无监听的 invalidate 不会重新执行）。
      final sub = container.listen(noticeListProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(noticeListProvider.future); // 等初始异步 build 完成
      final listCallsAfterListen = repo.listCalls;
      expect(listCallsAfterListen, 1);
      // 未读数 provider 懒初始化：helper 前未被读取，计数为 0。
      expect(repo.unreadCountCalls, 0);

      await markNoticesReadByRoute(container, [
        '/purchase/orders/x',
        '/subcontract/orders/y',
      ]);
      await container.read(noticeListProvider.future); // 等失效后的异步重建完成

      expect(repo.routeCalls, [
        ['/purchase/orders/x', '/subcontract/orders/y'],
      ]);
      // 列表失效重建一次；未读数 provider 首次实例化（启动 _tick + 立即 refresh）。
      expect(repo.listCalls, listCallsAfterListen + 1);
      expect(repo.unreadCountCalls, 2);
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
}
