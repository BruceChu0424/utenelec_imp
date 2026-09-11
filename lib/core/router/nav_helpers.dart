// 导航助手：来源感知跳转 + 返回（解决"从哪进回哪"）
//
// 问题：context.go(path) 不带来源，目标页返回只能写死一个去向；
// 账户/收付款类别等从多个入口（基础资料 hub / 财税部 dashboard）进，
// 写死回哪都不对。
//
// 方案：跳转时带 ?returnTo=<当前路径>；返回时先 pop（被 push 进来的页面回上一页），
// 栈空才读 returnTo，没有则用默认。配合工作台/ShellRoute 主 Tab 的 KeepAlive，
// context.go 回来源 Tab 复用同一实例，滚动位置随之保留。
//
// 用法：
//   卡片入口：onTap: () => goFrom(context, item.location)
//   页面返回：UtenBackButton(onPressed: () => backTo(context, defaultPath: RouteName.basicinfo))
//   保存后：context.replace(详情)；删除/「返回列表」：backTo(context, defaultPath: 列表路径)，
//   不要 context.go 硬编码列表（会抹掉栈下的来源页）。

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// 带来源跳转：在 path 上追加 ?returnTo=<当前路径>（已带 query 则合并）。
///
/// 当前路径取 matchedLocation（不含 query），避免来源链无限变长。
void goFrom(BuildContext context, String path) {
  final from = GoRouterState.of(context).matchedLocation;
  final uri = Uri.parse(path);
  final params = Map<String, String>.from(uri.queryParameters)
    ..['returnTo'] = from;
  context.go(uri.replace(queryParameters: params).toString());
}

/// 全站唯一返回契约（2026-09-10 收敛，docs/05-架构/路由设计.md「返回键契约」）：
/// 1. 能 pop 就 pop——被 push 进来的页面（任务中心→列表→详情、详情→关联页）
///    返回到上一页，栈下页面保留筛选/页码/未保存状态；
/// 2. 栈空（深链、hub 卡片 goFrom/context.go 直达）读 ?returnTo 回来源页；
/// 3. 再没有则回 [defaultPath]（模块 hub / 工作台）。
///
/// 此前 backTo 永远 context.go（整栈替换），约 70 个页面的返回键因此从三四层
/// 深处直接跳回 hub/工作台——这是用户反馈「点返回直接回到最外面」的统一根因。
/// 主 Tab（dashboard 等）由 ShellRoute PageView KeepAlive 保活，pop 回主 Tab
/// 路径只是取消 Offstage；context.go 回主 Tab 也复用原实例，滚动位置保留。
void backTo(BuildContext context, {required String defaultPath}) {
  if (context.canPop()) {
    try {
      context.pop();
      return;
    } catch (_) {
      // canPop 为真但当前 navigator 取不到（过渡/加载未就绪、嵌套 navigator 场景）
      // go_router 的 _findCurrentNavigator 会 null 崩；不抛，落到来源感知 go 兜底。
    }
  }
  final returnTo = GoRouterState.of(context).uri.queryParameters['returnTo'];
  context.go(returnTo ?? defaultPath);
}

/// 与 [backTo] 同义（历史名称保留给既有 39 处调用方，语义已合并：pop 优先，
/// 栈空读 returnTo，再无则 [defaultPath]）。新代码一律用 [backTo]。
void popOrBackTo(BuildContext context, {required String defaultPath}) =>
    backTo(context, defaultPath: defaultPath);

/// 当前匹配路径；无 GoRouter 上下文（widget 测试直接 pump）时回退 [fallback]。
///
/// 「返回即刷新」onPageResume 需要页面的稳定 location；路由内即 matchedLocation，
/// 测试环境没有路由就退回调用方已知的路由常量，注册不生效但不抛错。
String currentLocationOr(BuildContext context, String fallback) {
  try {
    return GoRouterState.of(context).matchedLocation;
  } catch (_) {
    return fallback;
  }
}
