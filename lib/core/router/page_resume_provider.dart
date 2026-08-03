// 「返回即刷新」信号：记录最近一次路由落点 + 单调递增 tick。
//
// 背景：工作台等主 Tab 由 Shell 保活（Offstage 隐藏不销毁），列表页被 push 进的
// 详情/编辑页压在栈下时也不销毁；从子页面返回时页面实例复用、不会重走 initState，
// 本地 State 与缓存 provider 仍停在旧数据——例如：销售订货单全流程走完回工作台，
// 计划部门角标要等 60s 轮询才出现；审计中心返回工作台，概览也不是最新的。
//
// 机制：app_router 在 routerDelegate 上挂监听，任何导航落定（go / push / pop /
// 系统返回手势 / 深链）后都 bump 一次本 provider（location = 新路径，不含 query）。
// 页面/外壳用 ref.onPageResume 注册：当自己再次成为当前路径时刷新数据。
//
// 触发规则（在 onPageResume 内判定）：仅当「上一落点不是我、新落点是我」才触发——
//   · 首次进入不触发（initState 已加载，避免重复请求）；
//   · 从我走进子页不触发（离开不是返回）；
//   · App 启动后的第一次落定不触发（页面刚建，数据是新的）。
//
// 与 list_refresh_provider 的分工：listRefresh 是「操作变更后精准刷新」（省请求），
// 本机制是「任何返回都刷新」，覆盖未 bump 的纯查看返回与跨模块返回。

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 最近一次导航落点。location 为 path（不含 query）；tick 单调递增。
typedef PageResumeState = ({String location, int tick});

/// 全局「返回即刷新」信号（单一数据源，由 app_router 写入）。
final pageResumeProvider = StateProvider<PageResumeState>(
  (ref) => (location: '', tick: 0),
);

/// 路由落定后由 app_router 调用：路径确实变化才 bump（go_router 偶尔原地通知）。
void bumpPageResume(Ref ref, String location) {
  final notifier = ref.read(pageResumeProvider.notifier);
  final cur = notifier.state;
  if (cur.location == location) return;
  notifier.state = (location: location, tick: cur.tick + 1);
}

/// 「返回即刷新」注册扩展。
extension PageResumeX on WidgetRef {
  /// 当 [myLocation] 再次成为当前路径（从其它页面/子页面返回）时执行 [refresh]。
  ///
  /// 用法（build 内，与 ref.listen 同位置；myLocation 建议用页面创建时捕获的
  /// `GoRouterState.of(context).matchedLocation`，不要在 build 里反复现取——
  /// 被 push 页遮住后现取到的是别人的路径）：
  /// ```
  /// _myLocation ??= GoRouterState.of(context).matchedLocation;
  /// ref.onPageResume(_myLocation!, () => _load(_pageNum));
  /// ```
  void onPageResume(String myLocation, void Function() refresh) {
    listen(pageResumeProvider, (prev, next) {
      if (prev == null) return;
      if (next.location != myLocation) return; // 到达的不是我
      if (prev.location == myLocation) return; // 从我出发/原地通知，不算返回
      if (prev.location.isEmpty) return; // App 启动首次落定，页面刚建已是新数据
      refresh();
    });
  }
}
