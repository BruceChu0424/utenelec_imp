// UtenScrollBehavior - 全局滚动行为
//
// 设计决策：抑制页面自动附加的滚动条。
// 桌面端（Windows/macOS/Web）MaterialScrollBehavior 默认会给可滚动区域
// 自动套上右侧 Scrollbar，视觉上显乱；统一覆盖 buildScrollbar 直接返回
// child。业务表格和长弹窗在各自的有界区域明确提供滚动条，避免内容发现度不足。
// 滚轮/触控板/拖拽滚动本身不受影响。

import 'package:flutter/material.dart';

/// 抑制隐式滚动条，保留默认平台滚动物理与设备拖拽配置。
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
