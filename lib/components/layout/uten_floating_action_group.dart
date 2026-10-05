import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/capsule_nav_metrics.dart';

/// 右下角悬浮操作组。
///
/// 组内业务动作（按钮/胶囊）高度统一为 [controlHeight]；宽度各自随内容
/// 收紧，不互相等宽拉伸（2026-10-04 用户口径：已选胶囊、取消等短按钮被
/// 长按钮撑宽显得空，每个控件内容多宽就多宽；计数文案变化时宽度自然跟随）。
class UtenFloatingActionGroup extends StatelessWidget {
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
  /// 而「已选 N 项」胶囊默认按表格工具条的 48 走——两者并排时矮 4px，用户一眼
  /// 就看出来了（2026-09-11 反馈）。这里对每个孩子统一下 minHeight，谁也不用
  /// 记得在调用点传高度；用 min 而非 tight，超大字号下按钮文案换行仍能长高。
  static const double controlHeight = 52;

  /// 正文末尾的可滚动留白，可把末行完整滚到悬浮操作组上方。
  /// 包含两行按钮、底部安全区及额外阅读空间；详情和编辑页共用。
  static const double scrollClearance = 200;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final availableWidth = (viewportWidth - UtenSpacing.s32)
        .clamp(0.0, maxWidth)
        .toDouble();

    // compact 悬浮胶囊避让：本组常挂在 Scaffold FAB 位或表格 Stage 的贴底
    // Positioned 上，靠自带底 padding 抬到胶囊上方（弹窗/抽屉里查不到 scope
    // 取 0，位置不变）。滚动末尾让位由各页滚动件另行查询，不在组内重复加。
    final capsuleOcclusion = UtenCapsuleNavScope.occlusionOf(context);

    return Padding(
      padding: EdgeInsets.only(bottom: capsuleOcclusion),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: availableWidth),
          child: Wrap(
            alignment: WrapAlignment.end,
            runAlignment: WrapAlignment.end,
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              for (final child in children)
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
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
    );
  }
}
