import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/capsule_nav_metrics.dart';

/// 右下角悬浮操作组。
///
/// 组内业务动作（按钮/胶囊）高度统一为 [controlHeight]；宽度各自随内容
/// 收紧，不互相等宽拉伸（2026-10-04 用户口径：已选胶囊、取消等短按钮被
/// 长按钮撑宽显得空，每个控件内容多宽就多宽；计数文案变化时宽度自然跟随）。
class UtenFloatingActionGroup extends StatefulWidget {
  const UtenFloatingActionGroup({
    super.key,
    required this.children,
    this.maxWidth = 1080,
  });

  final List<Widget> children;
  final double maxWidth;

  /// 悬浮组内控件的统一高度。
  ///
  /// 取值 = [UtenButtonSize.large] 的最小高度：组里的业务动作一律用 large，
  /// 与表格选择摘要沿同一套48dp主操作规格。这里对每个孩子统一下 minHeight，谁也不用
  /// 记得在调用点传高度；用 min 而非 tight，超大字号下按钮文案换行仍能长高。
  static const double controlHeight = 48;

  /// 正文末尾的可滚动留白，可把末行完整滚到悬浮操作组上方。
  /// 也是本组包含导航避让的总高度上限；超长组内滚动，所有动作仍可达。
  static const double scrollClearance = 200;

  @override
  State<UtenFloatingActionGroup> createState() =>
      _UtenFloatingActionGroupState();
}

class _UtenFloatingActionGroupState extends State<UtenFloatingActionGroup> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final availableWidth = (media.size.width - UtenSpacing.s32)
        .clamp(0.0, widget.maxWidth)
        .toDouble();

    // compact 悬浮胶囊避让：本组常挂在 Scaffold FAB 位或表格 Stage 的贴底
    // Positioned 上，靠自带底 padding 抬到胶囊上方（弹窗/抽屉里查不到 scope
    // 取 0，位置不变）。滚动末尾让位由各页滚动件另行查询，不在组内重复加。
    final capsuleOcclusion = UtenCapsuleNavScope.occlusionOf(context);
    final totalHeight = ((media.size.height - media.viewInsets.bottom) * 0.4)
        .clamp(
          UtenFloatingActionGroup.controlHeight,
          UtenFloatingActionGroup.scrollClearance,
        )
        .toDouble();
    final contentHeight = (totalHeight - capsuleOcclusion)
        .clamp(0.0, totalHeight)
        .toDouble();

    return Padding(
      padding: EdgeInsets.only(bottom: capsuleOcclusion),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: availableWidth,
            maxHeight: contentHeight,
          ),
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (_) => true,
            child: NotificationListener<ScrollNotification>(
              onNotification: (_) => true,
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  primary: false,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    runAlignment: WrapAlignment.end,
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s8,
                    children: [
                      for (final child in widget.children)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              UtenRadius.control,
                            ),
                            boxShadow: UtenElevation.mid(
                              isDark: theme.brightness == Brightness.dark,
                            ),
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: UtenFloatingActionGroup.controlHeight,
                            ),
                            child: child,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
