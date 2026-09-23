// 徽章汇总 provider 契约(ADR-108 / perf-frontend-01、-09, perf-production-exec-09):
//   · 登录后立即拉一次, 之后每 60s 一次(一分钟内只有 1 个计数请求, 此前约 40 个);
//   · 页面隐藏时 0 请求, 回到前台立即补一次;
//   · 登出后定时器停, 10 分钟 0 请求(此前登出后照样按 60s 打出 401);
//   · 单飞: 同一帧多处 refresh 只发 1 个请求, 在途期间再要只在返回后补 1 次;
//   · 取数失败 / 服务端标了没算出的入口, 保留上一次的数(徽章不闪 0)。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/app_visibility_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _BadgeApi extends ApiClient {
  _BadgeApi() : super(Dio());

  int calls = 0;
  Completer<void>? gate;
  Object? failWith;
  Map<String, dynamic> body = _summaryJson(todo: 1);

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.workbenchBadges) {
      throw StateError('unexpected GET $path');
    }
    calls++;
    final pending = gate;
    if (pending != null) await pending.future;
    final error = failWith;
    if (error != null) throw error;
    return body;
  }
}

Map<String, dynamic> _summaryJson({
  required int todo,
  int inProgress = 0,
  List<String> stale = const [],
}) => {
  'generatedAt': '2026-09-23T08:00:00Z',
  'entries': {
    'purchaseTaskCenter': {'todo': todo, 'inProgress': inProgress},
  },
  'modules': {
    'purchase': {'todo': todo, 'inProgress': inProgress},
  },
  'total': {'todo': todo, 'inProgress': inProgress},
  'facts': {'purchaseTask.pending': todo, 'notices.unread': 3},
  'staleEntries': stale,
};

final _scope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'user-1'),
);

(ProviderContainer, _BadgeApi) _container() {
  final api = _BadgeApi();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
    ],
  );
  // 保持订阅, 与页面 watch 一致。
  container.listen(badgeSummaryProvider, (_, _) {}, fireImmediately: true);
  return (container, api);
}

/// 让 provider 重建与其后的微任务/零延时任务走完(远小于任何轮询周期)。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('登录后立即拉一次, 一分钟内只有这一个请求, 之后每 60s 一次', (tester) async {
    final (container, api) = _container();

    await tester.pump();
    expect(api.calls, 1);
    expect(container.read(badgeTotalTodoProvider), 1);
    expect(container.read(unreadNoticeCountProvider), 3);

    await tester.pump(const Duration(seconds: 59));
    expect(api.calls, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(api.calls, 2);

    await tester.pump(const Duration(minutes: 3));
    expect(api.calls, 5);
    container.dispose();
  });

  testWidgets('页面隐藏时 0 请求; 回到前台立即补一次', (tester) async {
    final (container, api) = _container();
    await tester.pump();
    expect(api.calls, 1);

    container.read(appVisibilityProvider.notifier).debugSet(false);
    await tester.pump(const Duration(minutes: 10));
    expect(api.calls, 1);

    container.read(appVisibilityProvider.notifier).debugSet(true);
    await _settle(tester);
    expect(api.calls, 2);
    container.dispose();
  });

  testWidgets('登出后定时器停止, 10 分钟 0 请求, 数字归零', (tester) async {
    final (container, api) = _container();
    await tester.pump();
    expect(api.calls, 1);

    container.read(_scope.notifier).state = null;
    await tester.pump();
    expect(container.read(badgeTotalTodoProvider), 0);
    await tester.pump(const Duration(minutes: 10));
    expect(api.calls, 1);

    // 再登录(新身份)从零开始, 立即拉一次。
    container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'user-2',
    );
    await _settle(tester);
    expect(api.calls, 2);
    container.dispose();
  });

  testWidgets('换身份时旧身份的迟到响应作废, 不串到新身份', (tester) async {
    final (container, api) = _container();
    await tester.pump();
    expect(api.calls, 1);

    api.gate = Completer<void>();
    api.body = _summaryJson(todo: 9);
    unawaited(container.read(badgeSummaryProvider.notifier).refresh());
    await tester.pump();
    expect(api.calls, 2);

    // 请求在途时换成另一个人(代操作/换号): 旧响应随后到达也不能写进新身份。
    final oldGate = api.gate!;
    api.gate = null;
    container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'user-2',
    );
    api.body = _summaryJson(todo: 2);
    await _settle(tester);
    oldGate.complete();
    await _settle(tester);

    expect(container.read(badgeTotalTodoProvider), 2);
    container.dispose();
  });

  testWidgets('单飞: 同帧 5 次 refresh 只发 1 个请求; 在途再要只补 1 次', (tester) async {
    final (container, api) = _container();
    await tester.pump();
    expect(api.calls, 1);

    final notifier = container.read(badgeSummaryProvider.notifier);
    api.gate = Completer<void>();
    for (var i = 0; i < 5; i++) {
      unawaited(notifier.refresh());
    }
    await tester.pump();
    expect(api.calls, 2);

    // 在途期间又来 3 次(写操作成功、返回工作台、新通知), 返回后只补 1 次。
    for (var i = 0; i < 3; i++) {
      unawaited(notifier.refresh());
    }
    api.gate!.complete();
    api.gate = null;
    await tester.pump();
    await tester.pump();
    expect(api.calls, 3);
    container.dispose();
  });

  testWidgets('取数失败保留上一次的数; 没算出的入口沿用上一份', (tester) async {
    final (container, api) = _container();
    api.body = _summaryJson(todo: 4, inProgress: 2);
    await tester.pump();
    expect(
      container.read(badgeEntryTodoProvider(BadgeEntry.purchaseTaskCenter)),
      4,
    );

    api.failWith = StateError('network down');
    await container.read(badgeSummaryProvider.notifier).refresh();
    expect(
      container.read(badgeEntryTodoProvider(BadgeEntry.purchaseTaskCenter)),
      4,
    );
    expect(container.read(badgeTotalInProgressProvider), 2);

    // 服务端这次没算出采购任务中心(来源异常): 入口、容器、总数都沿用上一份。
    api.failWith = null;
    api.body = _summaryJson(todo: 0, stale: const ['purchaseTaskCenter']);
    await container.read(badgeSummaryProvider.notifier).refresh();
    expect(
      container.read(badgeEntryTodoProvider(BadgeEntry.purchaseTaskCenter)),
      4,
    );
    expect(container.read(badgeModuleTodoProvider(BadgeModule.purchase)), 4);
    expect(container.read(badgeTotalTodoProvider), 4);
    container.dispose();
  });

  testWidgets('轮询带回同样的数不触发重建', (tester) async {
    final (container, api) = _container();
    await tester.pump();
    var notified = 0;
    container.listen(badgeSummaryProvider, (_, _) => notified++);

    await container.read(badgeSummaryProvider.notifier).refresh();
    expect(api.calls, 2);
    expect(notified, 0);
    container.dispose();
  });
}
