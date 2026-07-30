// UtenScrollBehavior - 全局滚动行为
//
// 设计决策：全平台隐藏滚动条。
// 桌面端（Windows/macOS/Web）MaterialScrollBehavior 默认会给可滚动区域
// 自动套上右侧 Scrollbar，视觉上显乱；统一覆盖 buildScrollbar 直接返回
// child，所有页面（列表/下拉/弹窗内滚动区）都不再显示滚动条。
// 滚轮/触控板/拖拽滚动本身不受影响。

import 'package:flutter/material.dart';

/// Uten 全局滚动行为：隐藏滚动条，保留默认平台滚动物理与设备拖拽配置
class UtenScrollBehavior extends MaterialScrollBehavior {
  const UtenScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // 不包 Scrollbar，所有平台统一隐藏
    return child;
  }
}
