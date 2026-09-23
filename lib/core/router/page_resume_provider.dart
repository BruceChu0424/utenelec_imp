// 「返回即刷新」信号：记录最近一次路由落点 + 单调递增 tick。
//
// 背景：工作台等主 Tab 由 Shell 保活（Offstage 隐藏不销毁），列表页被 push 进的
// 详情/编辑页压在栈下时也不销毁；从子页面返回时页面实例复用、不会重走 initState，
// 本地 State 与缓存 provider 仍停在旧数据。
//
// 机制：app_router 在 routerDelegate 上挂监听，任何导航落定（go / push / pop /
// 系统返回手势 / 深链）后都 bump 一次本 provider（location = 新路径，不含 query）。
// 页面/外壳用 ref.onPageResume 注册：当自己再次成为当前路径时刷新数据。
//
// 触发规则(2026-09-23 ADR-108 收紧：按「数据变没变」而不是「导航了没有」)：
//   · 首次进入、从我走进子页、App 启动首次落定都不触发；
//   · 返回到我时，只有「期间本端成功写过数据(dataWriteRevisionProvider 前进)」或
//     「距上次刷新已超过 30 秒」才重拉——纯查看详情后返回不再整页重拉；
//   · 重拉推迟到返回转场走完之后([whenRouteTransitionsSettled])，不和动画抢帧；
//   · 页面登记的 refreshKeys(原 listRefreshTickProvider 精准刷新)只在本页就在栈顶
//     时立即重拉；被详情页盖着时只记下，返回时再拉——此前两套机制叠加，
//     列表页一次保存后要重拉两次。
//   · 断网恢复([pageRefreshRequestProvider])只让当前可见页重拉一次。

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/providers/list_refresh_provider.dart';
import '../network/data_write_revision.dart';
import 'route_transition_tracker.dart';

/// 最近一次导航落点。location 为 path（不含 query）；tick 单调递增。
typedef PageResumeState = ({String location, int tick});

/// 全局「返回即刷新」信号（单一数据源，由 app_router 写入）。
final pageResumeProvider = StateProvider<PageResumeState>(
  (ref) => (location: '', tick: 0),
);

/// 路由落定后由 app_router 调用：路径确实变化才 bump（go_router 偶尔原地通知）。
void bumpPageResume(Ref ref, String location) =>
    bumpPageResumeState(ref.read(pageResumeProvider.notifier), location);

/// [bumpPageResume] 的无 Ref 版本：拿到 notifier 的调用方([attachPageResume]、
/// 测试)直接写；路径未变的原地通知不 bump。
void bumpPageResumeState(
  StateController<PageResumeState> notifier,
  String location,
) {
  final cur = notifier.state;
  if (cur.location == location) return;
  notifier.state = (location: location, tick: cur.tick + 1);
}

/// 把 [router] 的导航落定接到「返回即刷新」信号上；返回解绑函数。
///
/// app_router 与页面导航测试共用这一份接线，测试里复现的就是线上的触发链：
/// 任何导航落定(go / push / replace / pop / 系统返回手势 / 深链)后，把当前
/// 路径写入 [notifier]。路由监听可能在 build 阶段触发，故推迟到微任务里再改
/// provider，避免 "Tried to modify a provider while the widget tree was building"。
void Function() attachPageResume(
  GoRouter router,
  StateController<PageResumeState> notifier,
) {
  var detached = false;
  void onNavigated() {
    if (detached) return;
    Future.microtask(() {
      if (detached) return;
      final location = topMatchedLocationOf(router);
      if (location != null) bumpPageResumeState(notifier, location);
    });
  }

  router.routerDelegate.addListener(onNavigated);
  return () {
    detached = true;
    router.routerDelegate.removeListener(onNavigated);
  };
}

/// 当前落点 = 栈顶路由的 matchedLocation(push 进来的页面也算)。
///
/// 不能用 `currentConfiguration.uri.path`：go_router 的 push / replace / pop
/// 不改 RouteMatchList.uri(源码 `RouteMatchList.push` 注释 "Imperative route
/// match doesn't change the uri")，它始终是最近一次 go 的位置。2026-09-10 返回
/// 键契约改成「能 pop 就 pop」后，列表 push 详情再 pop 回来的落点在 uri 上看
/// 完全没变、一次也不 bump——「返回即刷新」实际只对 go 生效，push/pop 流程
/// 全部静默失效(车间任务页从日报详情返回不刷新、_navigating 卡死即此)。
/// 页面注册用的 `GoRouterState.of(context).matchedLocation` 同样是栈顶口径，
/// 两边一致。空配置/错误页返回 null，不 bump。
String? topMatchedLocationOf(GoRouter router) {
  final config = router.routerDelegate.currentConfiguration;
  if (config.isEmpty || config.isError) return null;
  return config.last.matchedLocation;
}

/// 纯查看后返回时, 数据超过这么久才重拉(期间有写操作则不看时长, 一定重拉)。
const kPageResumeStaleAfter = Duration(seconds: 30);

/// 请求「当前可见页」立即重拉一次(断网恢复后由网络层推进)。
final pageRefreshRequestProvider = StateProvider<int>((ref) => 0);

class _ResumeState {
  _ResumeState(this.refreshedAt, this.revision);

  DateTime refreshedAt;
  int revision;
  bool pending = false;
}

/// 每个页面(element)按登记的路径各一份刷新记录, 随页面销毁回收
/// (外壳一个 element 同时登记工作台与通知两个落点)。
final Expando<Map<String, _ResumeState>> _resumeStates =
    Expando<Map<String, _ResumeState>>('pageResume');

/// 「返回即刷新」注册扩展。
extension PageResumeX on WidgetRef {
  /// 当 [myLocation] 再次成为当前路径(从其它页面/子页面返回)时按需执行 [refresh]。
  ///
  /// 只有期间本端写过数据、或数据已超过 [staleAfter] 才重拉, 且推迟到返回转场结束后。
  /// [refreshKeys] 为该页监听的精准刷新信号(bumpListRefresh 的 key): 本页在栈顶时
  /// 收到即重拉, 被盖住时留到返回再拉。[onReturn] 每次返回都执行(不受上述节流),
  /// 只用于复位页内交互状态(如子流程异常退出留下的「进行中」标记), 不要在里面取数。
  ///
  /// 用法（build 内，与 ref.listen 同位置；myLocation 建议用页面创建时捕获的
  /// `GoRouterState.of(context).matchedLocation`，不要在 build 里反复现取——
  /// 被 push 页遮住后现取到的是别人的路径）：
  /// ```
  /// _myLocation ??= GoRouterState.of(context).matchedLocation;
  /// ref.onPageResume(_myLocation!, () => _load(_pageNum), refreshKeys: [key]);
  /// ```
  void onPageResume(
    String myLocation,
    void Function() refresh, {
    Iterable<String> refreshKeys = const [],
    Duration staleAfter = kPageResumeStaleAfter,
    void Function()? onReturn,
  }) {
    final states = _resumeStates[this] ??= <String, _ResumeState>{};
    final state = states[myLocation] ??= _ResumeState(
      clock.now(),
      read(dataWriteRevisionProvider),
    );
    final element = this is BuildContext ? this as BuildContext : null;

    void run({required bool force}) {
      if (state.pending) return;
      if (!force &&
          read(dataWriteRevisionProvider) == state.revision &&
          clock.now().difference(state.refreshedAt) < staleAfter) {
        return;
      }
      state.pending = true;
      whenRouteTransitionsSettled(() {
        state.pending = false;
        if (element != null && !element.mounted) return;
        state
          ..refreshedAt = clock.now()
          ..revision = read(dataWriteRevisionProvider);
        refresh();
      });
    }

    bool onTop() =>
        _isTopLocation(read(pageResumeProvider).location, myLocation);

    listen(pageResumeProvider, (prev, next) {
      if (prev == null) return;
      if (next.location != myLocation) return; // 到达的不是我
      if (prev.location == myLocation) return; // 从我出发/原地通知，不算返回
      if (prev.location.isEmpty) return; // App 启动首次落定，页面刚建已是新数据
      if (onReturn != null) {
        whenRouteTransitionsSettled(() {
          if (element == null || element.mounted) onReturn();
        });
      }
      run(force: false);
    });
    for (final key in refreshKeys) {
      listen(listRefreshTickProvider(key), (_, _) {
        if (onTop()) run(force: true);
      });
    }
    listen(pageRefreshRequestProvider, (_, _) {
      if (onTop()) run(force: true);
    });
  }

  /// 嵌在页面里的分段/面板用: [key] 的精准刷新信号只在宿主页 [hostLocation] 就在栈顶时
  /// 立即 [refresh](转场静止后); 被详情页盖着时不动——宿主页返回时自己的「返回即刷新」
  /// 会带着分段一起重拉, 不再重拉两遍。
  void onListRefresh(String hostLocation, String key, void Function() refresh) {
    final element = this is BuildContext ? this as BuildContext : null;
    listen(listRefreshTickProvider(key), (_, _) {
      if (!_isTopLocation(read(pageResumeProvider).location, hostLocation)) {
        return;
      }
      whenRouteTransitionsSettled(() {
        if (element == null || element.mounted) refresh();
      });
    });
  }
}

/// 栈顶是否就是 [myLocation]。还没接上路由(落点为空, 如直接 pump 页面的测试)时按在栈顶处理。
bool _isTopLocation(String top, String myLocation) =>
    top.isEmpty || top == myLocation;
