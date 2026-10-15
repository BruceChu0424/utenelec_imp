// 基础资料详情页统一页签条：采用与分类栏同源的圆角矩形选中背景和边线。
// 旧厚下划线改为完整格选中态，保留真实TabController及TabBarView导航行为。
//
// 保留 TabController/TabBarView，分类栏同步点击和滑动；宽度不足时使用
// 共用分类选择面板。preferredSize 同时供详情页吸顶布局计算高度。
// 基础资料里的详情页（货品详情、客户/供应商详情）统一走本函数。
import 'package:flutter/material.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../core/theme/uten_tokens.dart';

PreferredSizeWidget buildUtenDetailTabBar(
  BuildContext context, {
  TabController? controller,
  required List<Widget> tabs,
  TextStyle? labelStyle,
}) {
  return PreferredSize(
    preferredSize: Size.fromHeight(UtenFilterRow.heightOf(context) + 16),
    child: _DetailCategories(
      controller: controller,
      tabs: tabs,
      labelStyle: labelStyle,
    ),
  );
}

class _DetailCategories extends StatelessWidget {
  const _DetailCategories({
    this.controller,
    required this.tabs,
    this.labelStyle,
  });

  final TabController? controller;
  final List<Widget> tabs;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final selectedController = controller ?? DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: selectedController,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: UtenSegmentRow<int>(
            segments: [
              for (var index = 0; index < tabs.length; index++)
                ButtonSegment(
                  value: index,
                  label: tabs[index] is Tab
                      ? ((tabs[index] as Tab).child ??
                            Text(
                              (tabs[index] as Tab).text ?? '',
                              style: labelStyle,
                            ))
                      : tabs[index],
                ),
            ],
            selected: {selectedController.index},
            showSelectedIcon: false,
            onSelectionChanged: (values) =>
                selectedController.animateTo(values.single),
          ),
        ),
      ),
    );
  }
}
