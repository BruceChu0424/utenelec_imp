// 基础资料详情页统一页签条（2026-09-25 用户口径「选中页签下面的那条指示条
// 加高，至少现在的三倍到五倍」）：Material TabBar 默认下划线只有 3px，隔着
// 屏幕看不出当前在哪个页签；统一抬到 12px（4 倍），年长用户也一眼可辨。
//
// 返回真正的 [TabBar]（而非包装组件）：宿主要用 `preferredSize.height` 做
// 吸顶高度（pinnedHeaderExtent）、按 TabBar 类型查找等，包一层都会丢。
// 基础资料里的详情页（货品详情、客户/供应商详情）统一走本函数。
import 'package:flutter/material.dart';

/// 选中页签下沿指示条厚度（TabBar 默认 3px 的 4 倍）。
const double kUtenDetailTabIndicatorWeight = 12;

TabBar buildUtenDetailTabBar(
  BuildContext context, {
  TabController? controller,
  required List<Widget> tabs,
  TextStyle? labelStyle,
}) {
  final theme = Theme.of(context);
  return TabBar(
    controller: controller,
    // 整页宽屏下页签居中铺满会很稀疏，靠左流式排布。
    isScrollable: true,
    tabAlignment: TabAlignment.start,
    labelColor: theme.colorScheme.primary,
    unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
    labelStyle: labelStyle,
    indicatorSize: TabBarIndicatorSize.tab,
    indicator: UnderlineTabIndicator(
      borderSide: BorderSide(
        width: kUtenDetailTabIndicatorWeight,
        color: theme.colorScheme.primary,
      ),
    ),
    tabs: tabs,
  );
}
