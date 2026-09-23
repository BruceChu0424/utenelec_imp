// 全局路由转场(ADR-108)。
//
// Web 与桌面: 统一约 150ms 的纯透明度淡入——只动新页, 不缩放、旧页不参与动画。
// 框架默认的 Zoom 转场在 Web 上不做快照(page_transitions_theme 的 useSnapshot 对 kIsWeb
// 恒为 false), 办公室 Windows + Chrome 下每次进出页面, 新旧两页(常见几十列表格)都要在
// 单线程 CanvasKit 上整棵缩放重绘到转场结束。移动端保留平台默认。
// 所有转场都经 [TrackedPageTransitionsBuilder] 登记, 供「返回即刷新」等到转场结束再重拉。
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../router/route_transition_tracker.dart';
import 'uten_anim.dart';

/// Web / 桌面用的轻量淡入。
class UtenFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const UtenFadePageTransitionsBuilder();

  @override
  Duration get transitionDuration => UtenAnim.fast;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: UtenAnim.standard),
      child: child,
    );
  }
}

/// 是否走轻量淡入: Web 一律是; 桌面(Windows/macOS/Linux)也是。
bool usesLightweightPageTransitions({
  bool isWeb = kIsWeb,
  TargetPlatform? platform,
}) {
  if (isWeb) return true;
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

/// 亮/暗两套主题共用的转场主题。
PageTransitionsTheme utenPageTransitionsTheme() {
  if (usesLightweightPageTransitions()) {
    const fade = TrackedPageTransitionsBuilder(
      UtenFadePageTransitionsBuilder(),
    );
    return const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: fade,
        TargetPlatform.iOS: fade,
        TargetPlatform.macOS: fade,
        TargetPlatform.windows: fade,
        TargetPlatform.linux: fade,
        TargetPlatform.fuchsia: fade,
      },
    );
  }
  // 移动端: 与框架默认一致, 只加登记。
  return const PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: TrackedPageTransitionsBuilder(
        PredictiveBackPageTransitionsBuilder(),
      ),
      TargetPlatform.iOS: TrackedPageTransitionsBuilder(
        CupertinoPageTransitionsBuilder(),
      ),
      TargetPlatform.macOS: TrackedPageTransitionsBuilder(
        CupertinoPageTransitionsBuilder(),
      ),
      TargetPlatform.windows: TrackedPageTransitionsBuilder(
        ZoomPageTransitionsBuilder(),
      ),
      TargetPlatform.linux: TrackedPageTransitionsBuilder(
        ZoomPageTransitionsBuilder(),
      ),
      TargetPlatform.fuchsia: TrackedPageTransitionsBuilder(
        ZoomPageTransitionsBuilder(),
      ),
    },
  );
}
