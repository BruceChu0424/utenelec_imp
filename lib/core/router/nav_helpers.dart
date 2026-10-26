// 导航助手：来源感知跳转 + 返回（解决"从哪进回哪"）
//
// 问题：context.go(path) 不带来源，目标页返回只能写死一个去向；
// 账户/收付款类别等从多个入口（基础资料 hub / 财税部 dashboard）进，
// 写死回哪都不对。
//
// 方案：跳转时带 ?returnTo=<当前路径>；返回时先 pop（被 push 进来的页面回上一页），
// 栈空才读 returnTo，没有则用默认。向下打开页面使用 push 保留来源实例；
// 返回时不重新创建列表，不重复首次取数。
//
// 用法：
//   卡片入口：onTap: () => goFrom(context, item.location)
//   页面返回：UtenBackButton(onPressed: () => backTo(context, defaultPath: RouteName.basicinfo))
//   保存后：context.replace(详情)；删除/「返回列表」：backTo(context, defaultPath: 列表路径)，
//   不要 context.go 硬编码列表（会抹掉栈下的来源页）。

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'route_names.dart';

/// Opens a link without returning the child page's lifetime to button feedback.
///
/// Use for navigation-only callbacks. Awaited visits that release a navigation
/// lock, refresh on return or consume a typed result use PageNavigationSession.
void pushPage(BuildContext context, String location, {Object? extra}) {
  unawaited(context.push<void>(location, extra: extra));
}

/// 带来源打开页面，并保留来源页的数据、分类、滚动位置和动画状态。
///
/// 主 Tab 由外壳保活，沿用 go 避免创建重复的隐藏 Tab；其余来源与 [pushFrom]
/// 使用同一压栈契约。原来的 go 会销毁普通列表，使“详情返回”变成首次加载。
/// 切换主导航、登录重定向和结束业务流程仍用显式 go/replace/backTo。
/// 编辑器的草稿入口设置 [retainSource] 为 false，继续经过路由离开保护；
/// 保存中的编辑器不能被隐藏后继续替换顶层路由。
void goFrom(BuildContext context, String path, {bool retainSource = true}) {
  final from = GoRouterState.of(context).matchedLocation;
  if (!retainSource ||
      const {
        RouteName.dashboard,
        RouteName.notice,
        RouteName.profile,
        RouteName.settings,
      }.contains(from)) {
    final uri = Uri.parse(path);
    context.go(
      uri
          .replace(queryParameters: {...uri.queryParameters, 'returnTo': from})
          .toString(),
    );
    return;
  }
  pushFrom<void>(context, path);
}

/// 带来源压栈，保留来源页的分类、筛选和滚动状态。
/// 普通 hub 和任务中心不属于主 Tab 的 KeepAlive 范围，所有向下入口均使用此契约。
/// 当前路径取 matchedLocation（不含 query），避免来源链无限变长。
Future<T?> pushFrom<T extends Object?>(BuildContext context, String path) {
  final from = GoRouterState.of(context).matchedLocation;
  final uri = Uri.parse(path);
  final params = Map<String, String>.from(uri.queryParameters)
    ..['returnTo'] = from;
  return context.push<T>(uri.replace(queryParameters: params).toString());
}

/// 全站唯一返回契约（2026-09-10 收敛，docs/05-架构/路由设计.md「返回键契约」）：
/// 1. 能 pop 就 pop——被 push 进来的页面（任务中心→列表→详情、详情→关联页）
///    返回到上一页，栈下页面保留业务分类与未保存状态，搜索按页面生命周期清空；
/// 2. 栈空（深链、context.go 直达）读 ?returnTo 回来源页；
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
String currentLocationOr(BuildContext context, String fallback) =>
    goRouterPageStateOrNull(context)?.matchedLocation ?? fallback;

/// Reads this declarative page's route identity, never a route behind a dialog
/// or an imperative Navigator page. Guard before subscribing to router state:
/// catching lookup errors alone cannot prevent inherited dependencies crossing
/// a route boundary while a dialog is building.
GoRouterState? goRouterPageStateOrNull(BuildContext context) {
  if (ModalRoute.of(context)?.settings is! Page) return null;
  try {
    return GoRouterState.of(context);
  } catch (_) {
    return null;
  }
}

/// 保存后只在紧邻前页是同一单据详情时 pop，复用宿主并触发返回刷新。
/// 草稿列表直接进入编辑、从别的单据进入编辑或深链直达，均 replace 到本单详情。
/// 不能仅凭 canPop 推断有详情宿主，否则草稿保存后会直接退回列表，无法继续审核。
void popSavedEditOrReplace(BuildContext context, String detailPath) {
  final router = GoRouter.of(context);
  final configuration = router.routerDelegate.currentConfiguration;
  final destination = Uri.parse(detailPath);
  if (router.canPop() && configuration.isNotEmpty) {
    // remove/last 会正确处理 ShellRoute 与 push 的 ImperativeRouteMatch，
    // 不使用仍停在最初 go 落点的 configuration.uri 来判断上一页。
    final previous = configuration.remove(configuration.last).lastOrNull;
    if (previous?.matchedLocation == destination.path) {
      router.pop();
      return;
    }
  }
  final returnTo = router.state.uri.queryParameters['returnTo'];
  router.replace<void>(
    returnTo != null && !destination.queryParameters.containsKey('returnTo')
        ? destination
              .replace(
                queryParameters: {
                  ...destination.queryParameters,
                  'returnTo': returnTo,
                },
              )
              .toString()
        : detailPath,
  );
}
