// 导航助手：来源感知跳转 + 返回（解决"从哪进回哪"）
//
// 问题：context.go(path) 不带来源，目标页返回只能写死一个去向；
// 账户/收付款类别等从多个入口（基础资料 hub / 财税部 dashboard）进，
// 写死回哪都不对。
//
// 方案：跳转时带 ?returnTo=<当前路径>；返回时读 returnTo，没有则用默认。
// 配合工作台/ShellRoute 主 Tab 的 KeepAlive，context.go 回来源 Tab
// 复用同一实例，滚动位置随之保留。
//
// 用法：
//   卡片入口：onTap: () => goFrom(context, item.location)
//   页面返回：UtenBackButton(onPressed: () => backTo(context, defaultPath: RouteName.basicinfo))

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// 带来源跳转：在 path 上追加 ?returnTo=<当前路径>（已带 query 则合并）。
///
/// 当前路径取 matchedLocation（不含 query），避免来源链无限变长。
void goFrom(BuildContext context, String path) {
  final from = GoRouterState.of(context).matchedLocation;
  final uri = Uri.parse(path);
  final params = Map<String, String>.from(uri.queryParameters)..['returnTo'] = from;
  context.go(uri.replace(queryParameters: params).toString());
}

/// 来源感知返回：读 returnTo 跳回来源页；没有则跳 [defaultPath]。
///
/// 主 Tab（dashboard 等）由 ShellRoute PageView KeepAlive 保活，
/// context.go 回主 Tab 复用原实例，滚动位置保留。
void backTo(BuildContext context, {required String defaultPath}) {
  final returnTo = GoRouterState.of(context).uri.queryParameters['returnTo'];
  context.go(returnTo ?? defaultPath);
}
