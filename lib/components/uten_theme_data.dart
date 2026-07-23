// Uten 通用动画/响应式 Provider 便捷访问
// 让组件能拿到当前性能档、断点等

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/responsive/breakpoint.dart';

/// 让 Widget 子树能拿到当前断点的 Provider
final breakpointProvider = Provider<UtenBreakpoint>((ref) {
  return UtenBreakpoint.compact; // 默认值，实际由 MediaQuery 决定
});

/// Uten 组件便捷扩展
extension UtenWidgetRef on WidgetRef {
  /// 当前断点
  UtenBreakpoint breakpointOf(BuildContext context) => context.breakpoint;
}
