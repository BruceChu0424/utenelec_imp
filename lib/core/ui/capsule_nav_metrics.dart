// UtenCapsuleNavScope - 悬浮胶囊导航（compact 外壳）遮挡高度的全站单一事实源。
//
// MainShellPage compact 分支里四个主 Tab 与业务子页面一律全高直通屏底，
// 胶囊导航以 overlay 浮在内容上（2026-09-28 用户口径：工作台的悬浮导航是对的，
// 其他页面导航不能占布局空间；滚到最底时内容要有安全空间不被胶囊挡住）。
// 内容避让不在各页写死，统一查本 scope：
//   - 页面滚动件末尾留白 += occlusion（滚到底最后一行能越过胶囊）
//   - 右下悬浮组 / 底部固定条的让位 = occlusion
//
// scope 只由 compact 外壳注入：medium+ 是左侧 Rail 无遮挡；弹窗 / 抽屉 / 全屏
// 路由在 shell 之外查不到 scope 取 0，天然不受影响（也无须按断点判断，
// 组件在弹窗里复用时不会多出无谓留白）。

import 'package:flutter/widgets.dart';

/// 胶囊导航遮挡信息：仅在 compact 外壳（MainShellPage）内可查到。
class UtenCapsuleNavScope extends InheritedWidget {
  const UtenCapsuleNavScope({
    super.key,
    required this.occlusion,
    required super.child,
  });

  /// 胶囊遮挡内容的总高度（含系统手势条与呼吸量）。
  final double occlusion;

  /// 胶囊外壳高度（FloatingCapsuleNavBar 同款；常量单一事实源在此，
  /// 组件层不 import features 也能取到）。
  static const double navHeight = 60;

  /// 胶囊距屏底距离（外壳 Positioned bottom）。
  static const double bottomOffset = 6;

  /// occlusion 里的额外呼吸量：内容完全越过胶囊后再留的一点间距。
  static const double breathing = 10;

  /// 外壳注入用：按当前 MediaQuery 手势条高度算遮挡总高。
  static double computeOcclusion(BuildContext context) {
    return navHeight + breathing + MediaQuery.paddingOf(context).bottom;
  }

  /// 查询点：不在 compact 外壳内（medium+ / 弹窗 / 抽屉）= 0。
  /// 在 build / didChangeDependencies 中调用以建立依赖。
  static double occlusionOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<UtenCapsuleNavScope>()
          ?.occlusion ??
      0;

  @override
  bool updateShouldNotify(UtenCapsuleNavScope oldWidget) =>
      oldWidget.occlusion != occlusion;
}
