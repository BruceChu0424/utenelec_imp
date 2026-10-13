// 基础资料详情页统一页签条：采用与分类栏同源的圆角矩形选中背景和边线。
// 旧厚下划线改为完整格选中态，保留真实TabController及TabBarView导航行为。
//
// 返回真正的 [TabBar]（而非包装组件）：宿主要用 `preferredSize.height` 做
// 吸顶高度（pinnedHeaderExtent）、按 TabBar 类型查找等，包一层都会丢。
// 基础资料里的详情页（货品详情、客户/供应商详情）统一走本函数。
import 'package:flutter/material.dart';
import '../../../core/theme/uten_category_tab_theme.dart';

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
    labelColor: theme.colorScheme.onSecondaryContainer,
    unselectedLabelColor: theme.colorScheme.onSurface,
    labelStyle: labelStyle,
    indicatorSize: TabBarIndicatorSize.tab,
    indicator: utenCategoryTabIndicator(theme.colorScheme),
    tabs: tabs,
  );
}
